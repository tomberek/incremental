#include <stdio.h>
int a_fn(void);
int b_fn(void);
int main(void) { printf("%d\n", a_fn() + b_fn()); return 0; }
