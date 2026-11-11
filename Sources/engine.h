#ifndef EM_ENGINE_H
#define EM_ENGINE_H

// EdgeMotion touch engine (C). Reads MultitouchSupport frames, drives the pointer,
// adds edge motion and reports multi-finger taps.

typedef struct {
    int   enabled;            // master switch

    // Pointer engine (takes over trackpad pointer motion from macOS)
    int   pointerTakeover;    // 1 = EdgeMotion moves the pointer for the trackpad
    float speed;              // overall multiplier (0.25 .. 3)
    float precFloor;          // slowest-speed factor, e.g. 0.3 (libinput)
    float precZone;           // mm/s below which motion is slowed down, e.g. 7
    float threshold;          // mm/s where acceleration starts, e.g. 130
    float incline;            // curvature of the acceleration, e.g. 0.0025
    float capMul;             // acceleration stops growing at threshold * capMul, e.g. 4

    // Dragging
    int   dragOtherFinger;    // click with one finger, move with another: the moving finger drives

    // Edge motion
    int   edgeEnabled;
    float edgeZonePct;        // 2 .. 25
    float edgeSpeed;          // 1 .. 40 points per 10 ms
    int   edgeDragOnly;
    int   edgeThreeFinger;

    // Taps (actions are handled by the app; the engine only detects)
    int   tap3;
    int   tap4;
} EMConfig;

typedef void (*EMTapCallback)(int fingers);

int    em_start(void);                         // returns number of multitouch devices (<0 = error)
void   em_set_config(const EMConfig *c);
void   em_get_default_config(EMConfig *c);
void   em_set_tap_callback(EMTapCallback cb);
int    em_should_suppress_system_motion(void); // 1 while EdgeMotion is driving the pointer
double em_curve_factor(const EMConfig *c, double speedMMs); // for drawing the curve
double em_points_per_mm(void);                 // base gain (points per mm at factor 1)
void   em_pad_size(float *wMM, float *hMM);    // physical trackpad size
long   em_magic(void);                         // marker on events EdgeMotion posts

#endif
