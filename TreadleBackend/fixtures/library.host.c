/* The C program that loads the library fixture (library.tir): it links against the library's import
   library (Windows) or the .so (Linux) and calls the exports as any C caller would. */
#include <stdio.h>

typedef struct P2 { int x, y; } P2;

void treadle_init(void);
int treadle_shutdown(void);
int kl_add(int a, int b);
P2 kl_flip(P2 p, int k);
void kl_keep(void);

int main(void)
{
    P2 p = { 3, 4 };
    P2 r;
    int leaks;
    treadle_init();
    printf("add %d\n", kl_add(1, 2));
    r = kl_flip(p, 10);
    printf("flip %d %d\n", r.x, r.y);
    kl_keep();
    fflush(stdout);
    leaks = treadle_shutdown();
    printf("leaks %d\n", leaks);
    return 0;
}
