K ?= ../FreeRTOS-Kernel
CC = arm-none-eabi-gcc
CFLAGS = -mcpu=cortex-m4 -mthumb -mfloat-abi=soft -Os -g -Wall -ffunction-sections -fdata-sections \
         -I. -I$(K)/include -I$(K)/portable/GCC/ARM_CM3
SRCS = main.c startup.c $(K)/tasks.c $(K)/queue.c $(K)/list.c \
       $(K)/portable/GCC/ARM_CM3/port.c $(K)/portable/MemMang/heap_4.c
all: firmware.elf firmware.bin
firmware.elf: $(SRCS) stm32f405.ld
	$(CC) $(CFLAGS) $(SRCS) -T stm32f405.ld -nostartfiles --specs=nano.specs --specs=nosys.specs -Wl,--gc-sections -Wl,-Map=firmware.map -o $@
firmware.bin: firmware.elf
	arm-none-eabi-objcopy -O binary $< $@
	arm-none-eabi-size firmware.elf
