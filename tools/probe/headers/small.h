/* small.h - a tiny C header to measure the import probes on (functions, struct, typedef, enum, macro). */
#ifndef SMALL_H
#define SMALL_H
#include <stddef.h>
#define SMALL_VERSION 3
#define SMALL_NAME "small"
typedef unsigned int small_id;
typedef enum small_kind { SMALL_NONE = 0, SMALL_POINT, SMALL_RECT = 10 } small_kind;
typedef struct small_point { int x, y; } small_point;
struct small_rect { small_point origin; small_point size; const char* label; };
typedef int (*small_callback)(void* user, small_id id);
small_id small_register(const char* name, small_callback cb, void* user);
void small_unregister(small_id id);
int small_area(const struct small_rect* r);
size_t small_count(void);
int small_printf(const char* fmt, ...);
extern int small_global;
extern int treadle_counter;
int treadle_limit_get(void);
#define treadle_limit treadle_limit_get()
#endif
