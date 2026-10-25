#include <stdint.h>

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;
extern int main(void);
extern void SVC_Handler(void);
extern void PendSV_Handler(void);
extern void SysTick_Handler(void);

void Default_Handler(void) { for (;;) { } }
void Reset_Handler(void);

__attribute__((section(".isr_vector"), used))
void (*const vector_table[16 + 16])(void) = {
  (void (*)(void))&_estack,   /* initial SP */
  Reset_Handler,
  Default_Handler,            /* NMI */
  Default_Handler,            /* HardFault */
  Default_Handler,            /* MemManage */
  Default_Handler,            /* BusFault */
  Default_Handler,            /* UsageFault */
  0, 0, 0, 0,
  SVC_Handler,
  Default_Handler,            /* DebugMon */
  0,
  PendSV_Handler,
  SysTick_Handler,
  /* the device IRQs stay on Default_Handler */
  [16 ... 31] = Default_Handler,
};

void Reset_Handler(void)
{
  uint32_t *src = &_sidata, *dst = &_sdata;
  while (dst < &_edata) *dst++ = *src++;
  for (dst = &_sbss; dst < &_ebss; ) *dst++ = 0;
  main();
  for (;;) { }
}
