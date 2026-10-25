#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

/* STM32F4 USART1 (APB2): SR at +0x00, DR at +0x04, CR1 at +0x0C */
#define USART1_SR  (*(volatile uint32_t *)0x40011000)
#define USART1_DR  (*(volatile uint32_t *)0x40011004)
#define USART1_CR1 (*(volatile uint32_t *)0x4001100C)

static void uart_putc(char c)
{
  while (!(USART1_SR & (1u << 7))) { }   /* TXE */
  USART1_DR = (uint32_t)c;
}

static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

static void uart_putu(uint32_t v)
{
  char buf[11];
  int i = 0;
  if (v == 0) buf[i++] = '0';
  while (v) { buf[i++] = (char)('0' + v % 10); v /= 10; }
  while (i) uart_putc(buf[--i]);
}

static QueueHandle_t queue;

static void producer(void *arg)
{
  (void)arg;
  for (uint32_t n = 1;; n++) {
    xQueueSend(queue, &n, portMAX_DELAY);
    vTaskDelay(pdMS_TO_TICKS(500));
  }
}

static void consumer(void *arg)
{
  uint32_t n;
  (void)arg;
  for (;;) {
    if (xQueueReceive(queue, &n, portMAX_DELAY) == pdTRUE) {
      uart_puts("consumer: got ");
      uart_putu(n);
      uart_puts(" at tick ");
      uart_putu((uint32_t)xTaskGetTickCount());
      uart_puts("\r\n");
    }
  }
}

int main(void)
{
  USART1_CR1 = (1u << 13) | (1u << 3);   /* UE | TE */
  uart_puts("FreeRTOS on STM32F405 (netduinoplus2)\r\n");

  queue = xQueueCreate(4, sizeof(uint32_t));
  xTaskCreate(producer, "producer", 256, NULL, 2, NULL);
  xTaskCreate(consumer, "consumer", 256, NULL, 1, NULL);
  vTaskStartScheduler();

  uart_puts("scheduler returned\r\n");
  for (;;) { }
}
