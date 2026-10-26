/* counter.c - defines the extern variable small.h declares (treadle_counter) and the function its macro treadle_limit reads (treadle_limit_get); the cvars set compiles it into the program (csource). */
int treadle_counter = 41;
int treadle_limit_get(void) { return 100; }
