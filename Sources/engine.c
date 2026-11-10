// engine.c — Windows-style edge motion engine for macOS trackpads (user space).
// Reads touches via the private MultitouchSupport framework and moves the cursor
// while a finger rests in the outer band of the trackpad.
//
// Options: --zone 0.08  (edge band, fraction of pad, 0.02..0.25)
//          --speed 8    (top speed, points per 10 ms)
//          --drag-only  (only while dragging)
//          --no3        (don't treat 3 fingers as three-finger drag)
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include "engine.h"

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

static float gZone = 0.08f, gSpeed = 8.0f;
static int gDragOnly = 0, gThree = 1;
static volatile int gEnabled = 1;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static int dirX, dirY, ticks;
static float depthX, depthY;

// --- tracking state (all under mu) ---
#define MAXT 16
typedef struct { int id; int blockX, blockY; } Landing;   // touches that landed inside a band
static Landing land[MAXT]; static int nLand;
static int trackId = -1000, stable = 0, prevCount = 0;
static float prevX, prevY, outX, outY;
static double cooldownUntil = 0;

#define INWARD_EXIT  0.015f   // pulling back inward this much in one frame cancels
#define MAX_JUMP     0.06f    // bigger per-frame jump = glitch / finger swap: ignore frame
#define ARM_FRAMES   3        // tracked touch must be stable this many frames
#define ARM_TRAVEL   0.004f   // outward travel inside the band needed to start
#define COOLDOWN_S   0.35     // after any untracked multi-finger contact, single finger waits

static int leftDown(void) {
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ? 1 : 0;
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void stopLocked(void) { dirX = dirY = 0; ticks = 0; depthX = depthY = 0; outX = outY = 0; }
static void resetLocked(void) { stopLocked(); trackId = -1000; stable = 0; }

static Landing *findLand(int id) {
    for (int i = 0; i < nLand; i++) if (land[i].id == id) return &land[i];
    return NULL;
}

static int contactCallback(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    (void)dev; (void)frame;
    if (!gEnabled) {
        pthread_mutex_lock(&mu); resetLocked(); nLand = 0; pthread_mutex_unlock(&mu);
        return 0;
    }

    int ids[MAXT]; float xs[MAXT], ys[MAXT]; int c = 0;
    for (int i = 0; i < n && c < MAXT; i++) {
        if (t[i].state != 3 && t[i].state != 4) continue;           // making touch / touching
        ids[c] = t[i].identifier;
        xs[c] = t[i].normalized.pos.x;
        ys[c] = 1.0f - t[i].normalized.pos.y;                       // y grows downward
        c++;
    }
    int btn = leftDown();

    pthread_mutex_lock(&mu);
    float zBase = gZone;

    // Remember, per touch, whether it LANDED inside a band (resting thumb / palm).
    Landing keep[MAXT]; int nk = 0;
    for (int i = 0; i < c; i++) {
        Landing *L = findLand(ids[i]);
        Landing e;
        if (L) e = *L;
        else {
            e.id = ids[i];
            e.blockX = (xs[i] < zBase || xs[i] > 1.0f - zBase);
            e.blockY = (ys[i] < zBase || ys[i] > 1.0f - zBase);
        }
        if (!(xs[i] < zBase || xs[i] > 1.0f - zBase)) e.blockX = 0;  // left the band once: armed
        if (!(ys[i] < zBase || ys[i] > 1.0f - zBase)) e.blockY = 0;
        keep[nk++] = e;
    }
    memcpy(land, keep, sizeof(Landing) * nk); nLand = nk;

    // Which point drives the pointer?
    int tid = -1000; float px = 0, py = 0; int dragging = btn; int bx = 0, by = 0;
    if (c == 1) {
        if (ts < cooldownUntil && !btn) { resetLocked(); pthread_mutex_unlock(&mu); return 0; }
        tid = ids[0]; px = xs[0]; py = ys[0];
        bx = land[0].blockX; by = land[0].blockY;
    } else if (c == 2 && btn) {
        // One finger holds the click, the other moves. Keep the same finger once chosen;
        // otherwise prefer the one NOT resting in a band (the clicking thumb usually is).
        int pick = -1;
        for (int i = 0; i < 2; i++) if (ids[i] == trackId) pick = i;
        if (pick < 0) {
            int b0 = land[0].blockX || land[0].blockY, b1 = land[1].blockX || land[1].blockY;
            pick = (b0 && !b1) ? 1 : (b1 && !b0) ? 0 : (ys[0] < ys[1] ? 0 : 1); // higher finger
        }
        tid = ids[pick]; px = xs[pick]; py = ys[pick];
        bx = land[pick].blockX; by = land[pick].blockY;
    } else if (c == 3 && gThree) {
        tid = -3; px = (xs[0] + xs[1] + xs[2]) / 3; py = (ys[0] + ys[1] + ys[2]) / 3;
        dragging = 1;
    } else {
        // lift, two-finger scroll, gestures, palm: stop, and make single-finger wait a bit
        if (c >= 2) cooldownUntil = ts + COOLDOWN_S;
        resetLocked();
        pthread_mutex_unlock(&mu);
        return 0;
    }

    if (tid != trackId || c != prevCount) {            // new or different touch: start fresh
        stopLocked();
        trackId = tid; prevCount = c; stable = 0;
        prevX = px; prevY = py;
        pthread_mutex_unlock(&mu);
        return 0;
    }

    float dx = px - prevX, dy = py - prevY;
    prevX = px; prevY = py;
    if (fabsf(dx) > MAX_JUMP || fabsf(dy) > MAX_JUMP) { stopLocked(); stable = 0; pthread_mutex_unlock(&mu); return 0; }
    if (stable < 1000) stable++;

    float z = (c == 3) ? zBase * 1.5f : zBase;
    int allowed = !gDragOnly || dragging;
    int zx = px < z ? -1 : (px > 1.0f - z ? 1 : 0);
    int zy = py < z ? -1 : (py > 1.0f - z ? 1 : 0);

    // Outward travel accumulated inside the band (a real slide, not one noisy frame).
    if (zx && !bx) { if (dx * zx > 0) outX += dx * zx; else if (dx * zx < 0) outX = 0; } else outX = 0;
    if (zy && !by) { if (dy * zy > 0) outY += dy * zy; else if (dy * zy < 0) outY = 0; } else outY = 0;

    if (allowed && stable >= ARM_FRAMES) {
        if (!dirX && zx && outX >= ARM_TRAVEL) dirX = zx;
        if (!dirY && zy && outY >= ARM_TRAVEL) dirY = zy;
    }
    if (dirX && (zx != dirX || dx * dirX < -INWARD_EXIT)) { dirX = 0; outX = 0; }
    if (dirY && (zy != dirY || dy * dirY < -INWARD_EXIT)) { dirY = 0; outY = 0; }
    if (!allowed) dirX = dirY = 0;
    if (!dirX && !dirY) ticks = 0;

    depthX = dirX ? clampf((dirX < 0 ? z - px : px - (1.0f - z)) / z, 0, 1) : 0;
    depthY = dirY ? clampf((dirY < 0 ? z - py : py - (1.0f - z)) / z, 0, 1) : 0;
    pthread_mutex_unlock(&mu);
    return 0;
}

static void moveCursor(float dx, float dy) {
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
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void *tickThread(void *arg) {
    (void)arg;
    for (;;) {
        usleep(10000);
        float mx = 0, my = 0;
        pthread_mutex_lock(&mu);
        if (dirX || dirY) {
            // start at 40% speed, ramp to 100% over ~0.6 s; deeper in the band = faster
            float ramp = 0.4f + 0.6f * (ticks < 60 ? ticks : 60) / 60.0f;
            if (dirX) mx = dirX * gSpeed * ramp * (0.5f + 0.5f * depthX);
            if (dirY) my = dirY * gSpeed * ramp * (0.5f + 0.5f * depthY);
            ticks++;
        }
        pthread_mutex_unlock(&mu);
        if (mx != 0 || my != 0) moveCursor(mx, my);
    }
    return NULL;
}


void edge_config(int enabled, float zonePct, float speed, int dragOnly, int threeFinger) {
    pthread_mutex_lock(&mu);
    gEnabled = enabled ? 1 : 0;
    gZone = clampf(zonePct / 100.0f, 0.02f, 0.25f);
    gSpeed = clampf(speed, 1, 40);
    gDragOnly = dragOnly ? 1 : 0;
    gThree = threeFinger ? 1 : 0;
    if (!gEnabled) { resetLocked(); nLand = 0; }
    pthread_mutex_unlock(&mu);
}

int edge_start(void) {
    static int started = 0;
    static int count = 0;
    if (started) return count;
    void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!mt) return -1;
    pMTDeviceCreateList = (CFMutableArrayRef (*)(void))dlsym(mt, "MTDeviceCreateList");
    pMTRegisterContactFrameCallback = (void (*)(MTDeviceRef, MTContactCallback))dlsym(mt, "MTRegisterContactFrameCallback");
    pMTDeviceStart = (void (*)(MTDeviceRef, int))dlsym(mt, "MTDeviceStart");
    if (!pMTDeviceCreateList || !pMTRegisterContactFrameCallback || !pMTDeviceStart) return -2;
    CFMutableArrayRef list = pMTDeviceCreateList();
    CFIndex nd = list ? CFArrayGetCount(list) : 0;
    for (CFIndex i = 0; i < nd; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
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
