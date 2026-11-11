// engine.c — EdgeMotion touch engine.
//
// Reads touch frames from Apple's private MultitouchSupport framework and:
//  * drives the pointer itself (optional), with a libinput-style acceleration curve
//    and "click with one finger, move with the other" dragging,
//  * keeps the pointer moving while a finger rests at the trackpad edge (edge motion),
//  * detects quick 3- and 4-finger taps.
//
// Acceleration curve adapted from libinput's touchpad profile (MIT, Red Hat et al.):
// slow down below a precision speed, 1:1 plateau, then a curve up to 4x the threshold.

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <mach/mach_time.h>
#include "engine.h"

// ---------- MultitouchSupport ----------
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerId, handId;
    MTVector normalized;
    float size;
    int zero1;
    float angle, majorAxis, minorAxis;
    MTVector mm;
    int zero2[2];
    float unk2;
} MTTouch;
typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFMutableArrayRef (*pMTDeviceCreateList)(void);
static void (*pMTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTDeviceStart)(MTDeviceRef, int);
static int  (*pMTDeviceGetSensorSurfaceDimensions)(MTDeviceRef, int *, int *);

#define EM_MAGIC        0x45444745L   // 'EDGE'
#define POINTS_PER_MM   11.69         // 1000 dpi normalisation x libinput TP_MAGIC_SLOWDOWN
#define PLATEAU         0.9           // libinput baseline
#define MAXT            16

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static EMConfig C;
static EMTapCallback gTapCB;
static float padW = 100.0f, padH = 60.0f;   // mm

static double nowS(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static int leftDown(void) {
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ? 1 : 0;
}

// ---------- defaults & curve ----------
void em_get_default_config(EMConfig *c) {
    memset(c, 0, sizeof(*c));
    c->enabled = 1;
    c->pointerTakeover = 1;
    c->speed = 1.0f;
    c->precFloor = 0.3f; c->precZone = 7.0f;
    c->threshold = 130.0f; c->incline = 0.0025f; c->capMul = 4.0f;
    c->dragOtherFinger = 1;
    c->edgeEnabled = 1; c->edgeZonePct = 8; c->edgeSpeed = 8; c->edgeDragOnly = 0; c->edgeThreeFinger = 1;
    c->tap3 = 1; c->tap4 = 0;
}

double em_curve_factor(const EMConfig *c, double v) {
    double f;
    if (c->precZone > 0.01 && v < c->precZone) {
        double a = (PLATEAU - c->precFloor) / c->precZone;
        f = c->precFloor + a * v;
        if (f > PLATEAU) f = PLATEAU;
    } else if (v < c->threshold) {
        f = PLATEAU;
    } else {
        double cap = c->threshold * (c->capMul > 1 ? c->capMul : 1);
        double vv = v < cap ? v : cap;
        f = c->incline * (vv / c->threshold) * (vv - c->threshold) + PLATEAU;
    }
    return f;
}

double em_points_per_mm(void) { return POINTS_PER_MM; }
long em_magic(void) { return EM_MAGIC; }
void em_pad_size(float *w, float *h) { if (w) *w = padW; if (h) *h = padH; }
void em_set_tap_callback(EMTapCallback cb) { gTapCB = cb; }

void em_set_config(const EMConfig *c) {
    pthread_mutex_lock(&mu);
    C = *c;
    C.speed = clampf(C.speed, 0.1f, 5.0f);
    C.precFloor = clampf(C.precFloor, 0.05f, 1.0f);
    C.precZone = clampf(C.precZone, 0.0f, 40.0f);
    C.threshold = clampf(C.threshold, 10.0f, 600.0f);
    C.incline = clampf(C.incline, 0.0f, 0.05f);
    C.capMul = clampf(C.capMul, 1.0f, 10.0f);
    C.edgeZonePct = clampf(C.edgeZonePct, 2, 25);
    C.edgeSpeed = clampf(C.edgeSpeed, 1, 40);
    pthread_mutex_unlock(&mu);
}

// ---------- posting ----------
static void postMove(float dx, float dy) {
    CGEventRef q = CGEventCreate(NULL);
    if (!q) return;
    CGPoint old = CGEventGetLocation(q);
    CFRelease(q);
    CGPoint p = CGPointMake(old.x + dx, old.y + dy);

    CGDirectDisplayID d; uint32_t cnt = 0;
    CGGetDisplaysWithPoint(p, 1, &d, &cnt);
    if (cnt == 0) {                                   // would leave all screens: clamp
        if (CGGetDisplaysWithPoint(old, 1, &d, &cnt) != kCGErrorSuccess || cnt == 0) d = CGMainDisplayID();
        CGRect b = CGDisplayBounds(d);
        p.x = fmax(b.origin.x, fmin(p.x, b.origin.x + b.size.width - 1));
        p.y = fmax(b.origin.y, fmin(p.y, b.origin.y + b.size.height - 1));
    }
    int btn = leftDown();
    CGEventRef e = CGEventCreateMouseEvent(NULL, btn ? kCGEventLeftMouseDragged : kCGEventMouseMoved,
                                           p, kCGMouseButtonLeft);
    if (!e) return;
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)lround(p.x - old.x));
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)lround(p.y - old.y));
    CGEventSetIntegerValueField(e, kCGEventSourceUserData, EM_MAGIC);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

// ---------- touch records ----------
typedef struct {
    int id;
    double land;        // when it touched down (MT time)
    double lastMoveT;   // last time it moved noticeably
    float x, y;         // mm, y grows downward
    float travel;       // total distance moved, mm
    int blockX, blockY; // landed inside an edge band
} Touch;

static Touch T[MAXT]; static int nT;

static Touch *findT(int id) { for (int i = 0; i < nT; i++) if (T[i].id == id) return &T[i]; return NULL; }

// pointer state
static int clicker = -1, prevBtn = 0;
static int driver = -1, dHave = 0;
static float dPrevX, dPrevY;
static double vEMA = 0, lastFactor = 0, lastTs = 0;
static double drvSeenAt = 0, drvMovedAt = 0;   // own clock
static int btnHeld = 0;

// edge state
static int dirX, dirY, ticks, edgeTrack = -1000, edgeStable = 0, edgeCount = 0;
static float ePrevX, ePrevY, outX, outY, depthX, depthY;
static double cooldownUntil = 0;
#define INWARD_EXIT 0.015f
#define MAX_JUMP    0.06f
#define ARM_FRAMES  3
#define ARM_TRAVEL  0.004f
#define COOLDOWN_S  0.35

// tap session
static int sessActive = 0, sessMax = 0, sessBtn = 0;
static double sessStart = 0, sessMaxAt = 0;
static float sessTravel = 0;
#define TAP_MAX_S       0.30
#define TAP_GATHER_S    0.15
#define TAP_MAX_TRAVEL  2.0f   // mm

static void edgeStop(void) { dirX = dirY = 0; ticks = 0; depthX = depthY = 0; outX = outY = 0; }
static void edgeReset(void) { edgeStop(); edgeTrack = -1000; edgeStable = 0; }

static int contactCallback(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    (void)dev; (void)frame;
    int ids[MAXT]; float xs[MAXT], ys[MAXT]; int c = 0;
    for (int i = 0; i < n && c < MAXT; i++) {
        if (t[i].state != 3 && t[i].state != 4) continue;           // making touch / touching
        ids[c] = t[i].identifier;
        xs[c] = t[i].normalized.pos.x * padW;
        ys[c] = (1.0f - t[i].normalized.pos.y) * padH;
        c++;
    }
    int btn = leftDown();
    double now = nowS();
    int fireTap = 0;
    float postX = 0, postY = 0; int doPost = 0;

    pthread_mutex_lock(&mu);
    if (!C.enabled) {
        nT = 0; edgeReset(); dHave = 0; driver = -1; sessActive = 0; clicker = -1;
        pthread_mutex_unlock(&mu);
        return 0;
    }
    float zone = C.edgeZonePct / 100.0f;

    // --- update touch records ---
    Touch keep[MAXT]; int nk = 0;
    for (int i = 0; i < c; i++) {
        Touch *o = findT(ids[i]);
        Touch r;
        float nx = xs[i] / padW, ny = ys[i] / padH;
        if (o) {
            r = *o;
            float d = hypotf(xs[i] - r.x, ys[i] - r.y);
            r.travel += d;
            if (d > 0.05f) r.lastMoveT = ts;
        } else {
            memset(&r, 0, sizeof r);
            r.id = ids[i]; r.land = ts; r.lastMoveT = 0;
            r.blockX = (nx < zone || nx > 1.0f - zone);
            r.blockY = (ny < zone || ny > 1.0f - zone);
        }
        r.x = xs[i]; r.y = ys[i];
        if (!(nx < zone || nx > 1.0f - zone)) r.blockX = 0;
        if (!(ny < zone || ny > 1.0f - zone)) r.blockY = 0;
        keep[nk++] = r;
    }
    memcpy(T, keep, sizeof(Touch) * nk); nT = nk;

    // --- tap session ---
    if (c > 0) {
        if (!sessActive) { sessActive = 1; sessStart = ts; sessMax = 0; sessBtn = 0; sessTravel = 0; }
        if (c > sessMax) { sessMax = c; sessMaxAt = ts; }
        if (btn) sessBtn = 1;
        for (int i = 0; i < nT; i++) if (T[i].travel > sessTravel) sessTravel = T[i].travel;
    } else if (sessActive) {
        sessActive = 0;
        double dur = ts - sessStart;
        if (!sessBtn && dur < TAP_MAX_S && (sessMaxAt - sessStart) < TAP_GATHER_S && sessTravel < TAP_MAX_TRAVEL) {
            if ((sessMax == 3 && C.tap3) || (sessMax == 4 && C.tap4)) fireTap = sessMax;
        }
    }

    // --- which finger holds the click ---
    if (btn && !prevBtn) {
        if (nT == 1) clicker = T[0].id;
        else if (nT >= 2) {
            // the finger that has moved least recently; tie -> the one lower on the pad
            int best = 0;
            for (int i = 1; i < nT; i++) {
                if (T[i].lastMoveT < T[best].lastMoveT - 0.02 ||
                    (fabs(T[i].lastMoveT - T[best].lastMoveT) <= 0.02 && T[i].y > T[best].y)) best = i;
            }
            clicker = T[best].id;
        }
    }
    if (!btn) clicker = -1;
    if (clicker != -1 && !findT(clicker)) clicker = -1;
    prevBtn = btn;
    btnHeld = btn;

    // --- which finger drives the pointer ---
    int drv = -1;
    if (nT == 1) drv = T[0].id;
    else if (nT == 2 && btn && C.dragOtherFinger) {
        if (clicker != -1) drv = (T[0].id == clicker) ? T[1].id : T[0].id;
        else drv = (T[0].land >= T[1].land) ? T[0].id : T[1].id;   // newest finger
    }

    // --- pointer engine ---
    if (C.pointerTakeover && drv != -1) {
        Touch *r = findT(drv);
        drvSeenAt = now;
        if (drv != driver || !dHave) {
            driver = drv; dHave = 1;
            dPrevX = r->x; dPrevY = r->y;
            vEMA = 0; lastFactor = 0; lastTs = ts;
        } else {
            float dx = r->x - dPrevX, dy = r->y - dPrevY;
            dPrevX = r->x; dPrevY = r->y;
            double dt = ts - lastTs; lastTs = ts;
            if (dt <= 0 || dt > 0.1) dt = 0.011;
            float dist = hypotf(dx, dy);
            if (dist > 0 && dist < 8.0f) {
                double inst = dist / dt;
                double alpha = 1.0 - exp(-dt / 0.03);
                vEMA += alpha * (inst - vEMA);
                double f = em_curve_factor(&C, vEMA);
                double avg = lastFactor > 0 ? (f + lastFactor) / 2 : f;
                lastFactor = f;
                double k = POINTS_PER_MM * C.speed * avg;
                postX = (float)(dx * k); postY = (float)(dy * k); doPost = 1;
                drvMovedAt = now;
            }
        }
    } else {
        dHave = 0; driver = -1;
    }

    // --- edge motion ---
    if (C.edgeEnabled) {
        int tid = -1000; float px = 0, py = 0; int dragging = btn; int bx = 0, by = 0; int tracked = 0;
        if (nT == 1) {
            if (!(ts < cooldownUntil && !btn)) { Touch *r = &T[0]; tid = r->id; px = r->x / padW; py = r->y / padH; bx = r->blockX; by = r->blockY; tracked = 1; }
        } else if (nT == 2 && btn) {
            int pick = -1;
            if (drv != -1) { for (int i = 0; i < 2; i++) if (T[i].id == drv) pick = i; }
            if (pick < 0) pick = (clicker == T[0].id) ? 1 : 0;
            Touch *r = &T[pick]; tid = r->id; px = r->x / padW; py = r->y / padH; bx = r->blockX; by = r->blockY; tracked = 1;
        } else if (nT == 3 && C.edgeThreeFinger) {
            tid = -3; px = (T[0].x + T[1].x + T[2].x) / 3 / padW; py = (T[0].y + T[1].y + T[2].y) / 3 / padH;
            dragging = 1; tracked = 1;
        } else if (nT >= 2) {
            cooldownUntil = ts + COOLDOWN_S;
        }

        if (!tracked) {
            edgeReset();
        } else if (tid != edgeTrack || nT != edgeCount) {
            edgeStop(); edgeTrack = tid; edgeCount = nT; edgeStable = 0; ePrevX = px; ePrevY = py;
        } else {
            float dx = px - ePrevX, dy = py - ePrevY;
            ePrevX = px; ePrevY = py;
            if (fabsf(dx) > MAX_JUMP || fabsf(dy) > MAX_JUMP) { edgeStop(); edgeStable = 0; }
            else {
                if (edgeStable < 1000) edgeStable++;
                float z = (nT == 3) ? zone * 1.5f : zone;
                int allowed = !C.edgeDragOnly || dragging;
                int zx = px < z ? -1 : (px > 1.0f - z ? 1 : 0);
                int zy = py < z ? -1 : (py > 1.0f - z ? 1 : 0);
                if (zx && !bx) { if (dx * zx > 0) outX += dx * zx; else if (dx * zx < 0) outX = 0; } else outX = 0;
                if (zy && !by) { if (dy * zy > 0) outY += dy * zy; else if (dy * zy < 0) outY = 0; } else outY = 0;
                if (allowed && edgeStable >= ARM_FRAMES) {
                    if (!dirX && zx && outX >= ARM_TRAVEL) dirX = zx;
                    if (!dirY && zy && outY >= ARM_TRAVEL) dirY = zy;
                }
                if (dirX && (zx != dirX || dx * dirX < -INWARD_EXIT)) { dirX = 0; outX = 0; }
                if (dirY && (zy != dirY || dy * dirY < -INWARD_EXIT)) { dirY = 0; outY = 0; }
                if (!allowed) dirX = dirY = 0;
                if (!dirX && !dirY) ticks = 0;
                depthX = dirX ? clampf((dirX < 0 ? z - px : px - (1.0f - z)) / z, 0, 1) : 0;
                depthY = dirY ? clampf((dirY < 0 ? z - py : py - (1.0f - z)) / z, 0, 1) : 0;
            }
        }
    } else {
        edgeReset();
    }
    EMTapCallback cb = gTapCB;
    pthread_mutex_unlock(&mu);

    if (doPost) postMove(postX, postY);
    if (fireTap && cb) cb(fireTap);
    return 0;
}

int em_should_suppress_system_motion(void) {
    pthread_mutex_lock(&mu);
    double now = nowS();
    int r = C.enabled && C.pointerTakeover && (now - drvSeenAt < 0.06) &&
            ((now - drvMovedAt < 0.25) || btnHeld);
    pthread_mutex_unlock(&mu);
    return r;
}

static void *tickThread(void *arg) {
    (void)arg;
    for (;;) {
        usleep(10000);
        float mx = 0, my = 0;
        pthread_mutex_lock(&mu);
        if (C.enabled && C.edgeEnabled && (dirX || dirY)) {
            float ramp = 0.4f + 0.6f * (ticks < 60 ? ticks : 60) / 60.0f;
            if (dirX) mx = dirX * C.edgeSpeed * ramp * (0.5f + 0.5f * depthX);
            if (dirY) my = dirY * C.edgeSpeed * ramp * (0.5f + 0.5f * depthY);
            ticks++;
        }
        pthread_mutex_unlock(&mu);
        if (mx != 0 || my != 0) postMove(mx, my);
    }
    return NULL;
}

int em_start(void) {
    static int started = 0, count = 0;
    if (started) return count;
    em_get_default_config(&C);
    void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!mt) return -1;
    pMTDeviceCreateList = (CFMutableArrayRef (*)(void))dlsym(mt, "MTDeviceCreateList");
    pMTRegisterContactFrameCallback = (void (*)(MTDeviceRef, MTContactCallback))dlsym(mt, "MTRegisterContactFrameCallback");
    pMTDeviceStart = (void (*)(MTDeviceRef, int))dlsym(mt, "MTDeviceStart");
    pMTDeviceGetSensorSurfaceDimensions = (int (*)(MTDeviceRef, int *, int *))dlsym(mt, "MTDeviceGetSensorSurfaceDimensions");
    if (!pMTDeviceCreateList || !pMTRegisterContactFrameCallback || !pMTDeviceStart) return -2;
    CFMutableArrayRef list = pMTDeviceCreateList();
    CFIndex nd = list ? CFArrayGetCount(list) : 0;
    for (CFIndex i = 0; i < nd; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        if (i == 0 && pMTDeviceGetSensorSurfaceDimensions) {
            int w = 0, h = 0;                                // hundredths of a millimetre
            pMTDeviceGetSensorSurfaceDimensions(dev, &w, &h);
            if (w > 2000 && h > 1000 && w < 40000 && h < 40000) { padW = w / 100.0f; padH = h / 100.0f; }
        }
        pMTRegisterContactFrameCallback(dev, contactCallback);
        pMTDeviceStart(dev, 0);
    }
    pthread_t th;
    pthread_create(&th, NULL, tickThread, NULL);
    pthread_detach(th);
    started = 1;
    count = (int)nd;
    return count;
}
