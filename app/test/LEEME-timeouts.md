# Por qué `npm test` lleva dos banderas raras

`"test": "node --test --test-force-exit --test-timeout=200000 test/*.test.js"`

## `--test-force-exit`

**El 2026-08-02 una corrida de `npm test` quedó viva 4 horas 50 minutos.** Un solo proceso worker
del runner nunca salió. Lo que se pudo comprobar de ese proceso colgado:

- **1,14 segundos de CPU en 4 h 50.** Estaba bloqueado, no en un bucle.
- **Sin procesos hijos, sin Electron vivo, sin un solo socket abierto.** No esperaba a la app.
- Retenía 6 MB entre los tres procesos del árbol: no era un problema de memoria.

No se llegó a determinar qué lo bloqueaba, y no se inventó una explicación. Lo que sí quedó claro
es lo accionable: **el `timeout` que se le pone a un test individual aborta el TEST, pero no
garantiza que el proceso worker termine.** Si queda un handle abierto que nadie cierra, el runner
espera para siempre.

`--test-force-exit` hace salir al runner cuando los tests terminaron, sin esperar a que el event
loop se vacíe. Es exactamente el caso de uso: acá los tests arrancan Electron y servidores de
verdad, y cualquiera de ellos puede dejar algo abierto.

**Es no determinístico:** la misma suite corrida 8 minutos después terminó en 114 segundos, y los
dos tests de Electron pasan solos (61 s y 71 s). Un test que se cuelga una de cada tantas veces es
peor que uno que falla siempre, porque nadie lo cree hasta que le pasa.

## `--test-timeout=200000`

Tope global de 200 s por test. Los dos tests que arrancan Electron de verdad tardan **61 s**
(`pagina-celular-arranca`) y **71 s** (`cuerpo-digital-electron`) con la máquina desocupada, y más
con la máquina cargada — por eso el número no puede ser chico. Pero tampoco puede no existir:
sin tope, un test colgado se lleva la suite entera.

## Y lo que no hay que hacer

**No corras `npm test | tail` ni `| head`.** `tail` no imprime NADA hasta que el stream termina,
así que si algo se cuelga no ves ni una línea y parece que el comando no arrancó nunca. El
2026-08-02 eso llevó a concluir que "`npm test` no emite salida en 7 minutos", que era falso: la
emitía toda desde el principio. Si querés guardar la salida, redirigila a un archivo
(`npm test > salida.txt 2>&1`) y leela aparte.
