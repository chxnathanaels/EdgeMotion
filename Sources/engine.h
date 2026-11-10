#ifndef EDGE_ENGINE_H
#define EDGE_ENGINE_H
// Start reading the trackpad. Returns number of multitouch devices (<0 = error).
int edge_start(void);
// zonePct: 2..25 (% of pad), speed: 1..40 (points per 10 ms)
void edge_config(int enabled, float zonePct, float speed, int dragOnly, int threeFinger);
#endif
