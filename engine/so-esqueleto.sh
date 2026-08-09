#!/usr/bin/env bash
# so-esqueleto.sh -- los archivos base del sistema operativo y sus pruebas. Lo usa mentis-so.sh.
#
# QUE HAY ACA Y POR QUE:
#   Dos cosas que NO puede escribir el modelo, porque son las que lo mantienen honesto:
#
#   1. EL MANEJADOR DE EXCEPCIONES. Cuando un kernel bare-metal se cae, por defecto no imprime
#      nada: se queda mudo o se reinicia en loop. Un modelo frente a "no hubo salida" no puede
#      hacer otra cosa que probar al azar. Con este manejador, la misma caída se convierte en
#      "Store page fault (mcause=7) en 0x80001234" -- y eso sí se puede arreglar. Es la diferencia
#      entre un bucle que converge y uno que gira en falso (ERR-098: las observaciones que mienten
#      mandan a chocar).
#
#   2. LAS PRUEBAS DE CADA HITO. Son del arnés, no del modelo. El modo de falla más común de un
#      bucle autónomo no es rendirse: es arreglar la prueba en vez del código. Acá se escriben una
#      vez, se les toma la huella, y si cambian el bucle se detiene.
#
# LA HAL DE DOS PLACAS, DESDE EL PRIMER HITO:
#   qemu 'virt' NO es el Tang Primer 20K: distinto mapa de memoria, distinta UART. Iterar ocho
#   hitos enteros en qemu y descubrir después que nada arranca en la FPGA es el fracaso predecible
#   de todo esto. Por eso lo único específico de cada placa (la dirección de la UART y el linker
#   script) vive detrás de una capa mínima desde el hito 1, y todo lo demás es común.

# so_escribir_esqueleto <carpeta>
so_escribir_esqueleto() {
  local d="$1"
  mkdir -p "$d/kernel" "$d/pruebas" || return 1

  # ---------- arranque ----------
  cat > "$d/kernel/start.S" <<'ASM'
/* Primer código que corre al encender. Deja la pila lista y salta a C.
   No lo toques salvo que sepas exactamente lo que hacés: si la pila queda mal,
   TODO lo demás falla de formas que no parecen tener nada que ver con la pila. */
.section.text.init
.globl _start
_start:
    /* Un solo hart: los demás quedan estacionados. En qemu virt puede arrancar más de uno. */
    csrr  t0, mhartid
    bnez  t0, parar

    la    sp, _pila_tope          /* pila */
    la    t0, trampa_entrada      /* vector de excepciones: sin esto, un fallo deja la placa muda */
    csrw  mtvec, t0

    /*.bss a cero: C da por sentado que las variables globales arrancan en cero. */
    la    t0, _bss_inicio
    la    t1, _bss_fin
limpiar_bss:
    bgeu  t0, t1, ir_a_main
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     limpiar_bss

ir_a_main:
    call  kmain
parar:
    wfi
    j     parar

/* Entrada de excepciones. Guarda lo mínimo y le pasa el diagnóstico a C. */
.align 4
.globl trampa_entrada
trampa_entrada:
    addi  sp, sp, -16
    sw    ra, 0(sp)
    csrr  a0, mcause
    csrr  a1, mepc
    csrr  a2, mtval
    call  trampa_informar
    lw    ra, 0(sp)
    addi  sp, sp, 16
    j     parar
ASM

  # ---------- linker: lo unico distinto entre placas, junto con la UART ----------
  cat > "$d/kernel/virt.ld" <<'LD'
/* Mapa de memoria de qemu -machine virt: la RAM arranca en 0x80000000. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ram (rwxa) : ORIGIN = 0x80000000, LENGTH = 128M }
SECTIONS {
.text : { *(.text.init) *(.text*) } > ram
.rodata : { *(.rodata*) } > ram
.data : { *(.data*) } > ram
.bss : { _bss_inicio =.; *(.bss*) *(COMMON) _bss_fin =.; } > ram
. = ALIGN(16);
. =. + 64K;
  _pila_tope =.;
}
LD

  cat > "$d/kernel/tang.ld" <<'LD'
/* Mapa de memoria del Tang Primer 20K (soft-core RISC-V sobre la FPGA Gowin).
   Los valores dependen de cómo se genere el núcleo; están acá para que el día que exista la
   placa haya que tocar UN archivo y no todo el kernel. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ram (rwxa) : ORIGIN = 0x00000000, LENGTH = 32K }
SECTIONS {
.text : { *(.text.init) *(.text*) } > ram
.rodata : { *(.rodata*) } > ram
.data : { *(.data*) } > ram
.bss : { _bss_inicio =.; *(.bss*) *(COMMON) _bss_fin =.; } > ram
. = ALIGN(16);
. =. + 4K;
  _pila_tope =.;
}
LD

  # ---------- HAL ----------
  cat > "$d/kernel/hal.h" <<'H'
/* Lo UNICO que cambia entre qemu y la FPGA. Todo el resto del kernel se escribe contra esto.
   Si algo específico de una placa se cuela fuera de este archivo y de su.c, el día que llegue
   el hardware no va a arrancar nada. */
#ifndef HAL_H
#define HAL_H

void hal_uart_init(void);
void hal_uart_putc(char c);
void hal_salir(int codigo);   /* termina la ejecución (en qemu apaga la máquina) */

/* Utilidades comunes a las dos placas. */
void kputs(const char *s);
void kputhex(unsigned long v);
void kputdec(unsigned long v);

#endif
H

  cat > "$d/kernel/hal_virt.c" <<'C'
/* Placa: qemu -machine virt. UART NS16550A en 0x10000000, dispositivo de salida en 0x100000. */
#include "hal.h"

#define UART_BASE 0x10000000UL
#define SALIDA    0x100000UL

static volatile unsigned char *const uart = (unsigned char *)UART_BASE;

void hal_uart_init(void) { /* qemu la deja lista; no hace falta configurarla */ }

void hal_uart_putc(char c) {
    while ((uart[5] & 0x20) == 0) { }   /* esperar a que el transmisor esté libre */
    uart[0] = (unsigned char)c;
}

void hal_salir(int codigo) {
    /* Dispositivo sifive_test: escribirle apaga qemu. Sin esto, una prueba que termina bien
       deja qemu corriendo para siempre y el arnés tiene que matarlo por tiempo -- que se
       parece demasiado a un cuelgue de verdad. */
    volatile unsigned int *s = (unsigned int *)SALIDA;
    *s = codigo == 0 ? 0x5555 : (0x3333 | (codigo << 16));
    for (;;) { }
}
C

  cat > "$d/kernel/hal_tang.c" <<'C'
/* Placa: Tang Primer 20K. Las direcciones dependen del núcleo RISC-V que se sintetice en la
   FPGA; se ajustan acá cuando exista la placa. El resto del kernel no se entera. */
#include "hal.h"

#define UART_BASE 0x02000000UL

static volatile unsigned int *const uart = (unsigned int *)UART_BASE;

void hal_uart_init(void) { }

void hal_uart_putc(char c) {
    while (uart[1] & 1) { }     /* esperar mientras esté ocupada */
    uart[0] = (unsigned int)c;
}

void hal_salir(int codigo) {
    (void)codigo;
    for (;;) { }                /* una placa real no se apaga sola: queda detenida */
}
C

  cat > "$d/kernel/comun.c" <<'C'
#include "hal.h"

void kputs(const char *s) { while (*s) hal_uart_putc(*s++); }

void kputhex(unsigned long v) {
    static const char d[] = "0123456789abcdef";
    kputs("0x");
    for (int i = (int)(sizeof(unsigned long) * 2) - 1; i >= 0; i--)
        hal_uart_putc(d[(v >> (i * 4)) & 0xf]);
}

void kputdec(unsigned long v) {
    char b[24]; int i = 0;
    if (v == 0) { hal_uart_putc('0'); return; }
    while (v) { b[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i--) hal_uart_putc(b[i]);
}
C

  # ---------- el manejador de excepciones: LA pieza que hace util al bucle ----------
  cat > "$d/kernel/trampa.c" <<'C'
/* Convierte una caída muda en un diagnóstico que se puede arreglar.
   Sin esto, un kernel que se cae no dice NADA y el que lo tenga que arreglar -- persona o
   modelo -- sólo puede probar cosas al azar. */
#include "hal.h"

static const char *motivo(unsigned long c) {
    switch (c) {
        case 0:  return "instruccion mal alineada";
        case 1:  return "fallo al buscar la instruccion";
        case 2:  return "instruccion ilegal";
        case 3:  return "breakpoint";
        case 4:  return "lectura mal alineada";
        case 5:  return "fallo de lectura";
        case 6:  return "escritura mal alineada";
        case 7:  return "fallo de escritura";
        case 8:  return "llamada al sistema";
        case 11: return "llamada al sistema (modo maquina)";
        case 12: return "fallo de pagina al buscar instruccion";
        case 13: return "fallo de pagina al leer";
        case 15: return "fallo de pagina al escribir";
        default: return "desconocido";
    }
}

void trampa_informar(unsigned long causa, unsigned long epc, unsigned long tval) {
    /* Formato fijo: mentis-so.sh lo parsea y traduce la direccion a archivo:linea con addr2line. */
    kputs("\n*** EXCEPCION ***\n");
    kputs("  motivo : "); kputs(motivo(causa & 0x7fffffff));
    kputs(" (mcause="); kputdec(causa & 0x7fffffff); kputs(")\n");
    kputs("  mepc   : "); kputhex(epc);  kputs("\n");
    kputs("  mtval  : "); kputhex(tval); kputs("\n");
    hal_salir(70);
}
C

  # ---------- las pruebas de cada hito: INMUTABLES ----------
  cat > "$d/pruebas/hito1.c" <<'C'
/* HITO 1 -- arranca y no se cae.
   La prueba mas simple posible, y la que mas veces salva: si el kernel no llega ni a esta linea,
   el problema esta en el arranque (pila, linker,.bss) y no tiene sentido mirar nada mas. */
#include "../kernel/hal.h"
void kmain(void) {
    hal_uart_init();
    kputs("HITO1: OK\n");
    hal_salir(0);
}
C

  cat > "$d/pruebas/hito2.c" <<'C'
/* HITO 2 -- imprime por la UART.
   Se piden varias lineas y un numero: una UART a medio andar suele imprimir el primer caracter
   y despues perderse, asi que una sola linea corta no alcanza para dar esto por bueno. */
#include "../kernel/hal.h"
void kmain(void) {
    hal_uart_init();
    for (int i = 1; i <= 3; i++) { kputs("linea "); kputdec((unsigned long)i); kputs("\n"); }
    kputhex(0xdeadbeefUL); kputs("\n");
    kputs("HITO2: OK\n");
    hal_salir(0);
}
C

  cat > "$d/pruebas/hito3.c" <<'C'
/* HITO 3 -- el manejador de excepciones funciona.
   Se provoca una excepcion A PROPOSITO. Que el kernel "no se caiga" no prueba nada; lo que hay
   que probar es que cuando se cae, LO CUENTA. Si este hito no pasa, todos los siguientes se
   depuran a ciegas. */
#include "../kernel/hal.h"
void kmain(void) {
    hal_uart_init();
    kputs("HITO3: provocando una excepcion a proposito\n");
    volatile unsigned int *malo = (unsigned int *)0x0000000CUL;
    *malo = 1;                      /* escritura invalida -> deberia entrar a la trampa */
    kputs("HITO3: FALLO -- no salto la excepcion\n");
    hal_salir(1);
}
C

  cat > "$d/pruebas/hito4.c" <<'C'
/* HITO 4 -- memoria: reservar y liberar.
   Se verifica lo que de verdad rompe un allocator: que dos reservas no se pisen, y que la
   memoria liberada se pueda volver a usar. Reservar una sola vez no prueba nada. */
#include "../kernel/hal.h"
void *kmalloc(unsigned long n);
void kfree(void *p);
void kmain(void) {
    hal_uart_init();
    char *a = (char *)kmalloc(64);
    char *b = (char *)kmalloc(64);
    if (!a || !b) { kputs("HITO4: FALLO -- kmalloc devolvio nulo\n"); hal_salir(1); }
    for (int i = 0; i < 64; i++) { a[i] = (char)0xAA; b[i] = (char)0x55; }
    for (int i = 0; i < 64; i++)
        if (a[i] != (char)0xAA || b[i] != (char)0x55) {
            kputs("HITO4: FALLO -- dos reservas se pisan\n"); hal_salir(1);
        }
    kfree(a); kfree(b);
    for (int v = 0; v < 50; v++) { void *p = kmalloc(32); if (!p) { kputs("HITO4: FALLO -- se agoto la memoria al reciclar\n"); hal_salir(1); } kfree(p); }
    kputs("HITO4: OK\n");
    hal_salir(0);
}
C

  cat > "$d/pruebas/hito5.c" <<'C'
/* HITO 5 -- interrupciones de reloj.
   Se exige una cantidad MINIMA de tics: un timer que dispara una sola vez y se queda quieto
   pasaria una prueba de "hubo al menos un tic", y es un bug clasico. */
#include "../kernel/hal.h"
void timer_init(unsigned long intervalo);
extern volatile unsigned long tics;
void kmain(void) {
    hal_uart_init();
    tics = 0;
    timer_init(100000);
    for (volatile unsigned long i = 0; i < 200000000UL && tics < 5; i++) { }
    kputs("tics: "); kputdec(tics); kputs("\n");
    if (tics >= 5) kputs("HITO5: OK\n"); else kputs("HITO5: FALLO -- el reloj no dio 5 tics\n");
    hal_salir(tics >= 5 ? 0 : 1);
}
C

  cat > "$d/pruebas/hito6.c" <<'C'
/* HITO 6 -- dos tareas que se alternan.
   Se verifica el ORDEN, no que ambas corran: dos tareas donde una termina y despues arranca la
   otra no es multitarea. Tiene que haber ida y vuelta. */
#include "../kernel/hal.h"
void tareas_init(void);
void tarea_crear(void (*fn)(void));
void tarea_ceder(void);
void tareas_correr(void);

static volatile int orden[8];
static volatile int n = 0;

static void tarea_a(void) { for (int i = 0; i < 3; i++) { if (n < 8) orden[n++] = 1; tarea_ceder(); } }
static void tarea_b(void) { for (int i = 0; i < 3; i++) { if (n < 8) orden[n++] = 2; tarea_ceder(); } }

void kmain(void) {
    hal_uart_init();
    tareas_init();
    tarea_crear(tarea_a);
    tarea_crear(tarea_b);
    tareas_correr();
    kputs("orden: ");
    for (int i = 0; i < n; i++) kputdec((unsigned long)orden[i]);
    kputs("\n");
    int alterna = (n >= 4);
    for (int i = 1; i < n; i++) if (orden[i] == orden[i-1]) alterna = 0;
    kputs(alterna ? "HITO6: OK\n" : "HITO6: FALLO -- las tareas no se alternan\n");
    hal_salir(alterna ? 0 : 1);
}
C

  cat > "$d/pruebas/hito7.c" <<'C'
/* HITO 7 -- entrada por la UART.
   Lo que se escribe por la consola tiene que poder leerse. En qemu la entrada se le manda por
   la misma consola serie. */
#include "../kernel/hal.h"
int hal_uart_getc_nb(void);   /* -1 si no hay nada */
void kmain(void) {
    hal_uart_init();
    kputs("HITO7: escribiendo y leyendo\n");
    int leidos = 0;
    for (volatile unsigned long i = 0; i < 50000000UL && leidos < 1; i++) {
        int c = hal_uart_getc_nb();
        if (c >= 0) { kputs("leido: "); hal_uart_putc((char)c); kputs("\n"); leidos++; }
    }
    kputs(leidos > 0 ? "HITO7: OK\n" : "HITO7: FALLO -- no llego ningun caracter\n");
    hal_salir(leidos > 0 ? 0 : 1);
}
C

  cat > "$d/pruebas/hito8.c" <<'C'
/* HITO 8 -- video por HDMI.
   Este hito NO se puede verificar en qemu: la salida de video es del hardware de la FPGA. Queda
   escrito para que exista el objetivo, pero mentis-so.sh lo marca como "necesita la placa" en vez
   de fingir que lo probo. Decirlo es mejor que dar un verde que no significa nada. */
#include "../kernel/hal.h"
void kmain(void) {
    hal_uart_init();
    kputs("HITO8: requiere la placa fisica (salida HDMI)\n");
    hal_salir(0);
}
C

  return 0
}
