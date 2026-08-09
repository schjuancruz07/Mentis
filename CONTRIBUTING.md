# Cómo contribuir

Gracias por pasar. Antes que nada, algo honesto: **Mentis es un proyecto personal**, no un
producto con equipo detrás. Se publica por si a alguien le sirve. Eso define cómo funciona esto:

- **No hay soporte.** Si algo no te anda, podés abrir un issue, pero puede pasar tiempo hasta que
  alguien lo mire. No hay tiempos de respuesta prometidos.
- **Los cambios se aceptan con criterio.** El proyecto tiene una dirección y decisiones tomadas a
  propósito. Un pull request bien hecho puede igual no entrar si no encaja.
- **No hace falta que contribuyas.** Clonalo, usalo, cambialo para vos. La licencia lo permite y
  es un uso perfectamente válido.

## Si encontraste un problema

Abrí un issue contando **qué esperabas que pasara y qué pasó**. Sirve muchísimo:

- Qué versión de Windows tenés.
- La salida de `bash mentis-diagnostico.sh` (revisá que no tenga claves antes de pegarla).
- Los pasos para que vuelva a pasar.

Un "no funciona" sin nada más es casi imposible de arreglar.

## Si querés mandar código

1. **Abrí un issue primero** si es un cambio grande. Da lástima que alguien escriba doscientas
   líneas y después no entren por una decisión de diseño que se podría haber charlado antes.
2. **Los tests tienen que pasar.** Están en `tests/` y se corren con `bash tests/test-loquesea.sh`.
   No es opcional: el sistema de publicación no deja publicar con un test en rojo.
3. **Si arreglás un bug, escribí el test que lo hubiera agarrado.** Un arreglo sin test es un
   arreglo que va a volver.
4. **Seguí el estilo de los comentarios.** Este código explica *por qué* está hecho así, no *qué*
   hace la línea siguiente. Cuando hay una medición detrás de una decisión, el número está
   escrito al lado. Si tu cambio se basa en una medición, ponela.

## Cómo está armado

```
engine/         El motor: el agente, los modelos, la voz, la búsqueda
app/            La ventana (Electron)
capabilities/   Habilidades sueltas: documentos, imágenes, hardware
mcp-bridge/     Conexión a servicios externos por MCP
tests/          Las pruebas
```

El motor es bash y Python; la ventana es Electron. `mentis-chat.sh` funciona en una consola sin
abrir la aplicación, y es la forma más rápida de probar un cambio del motor.

## Sobre el idioma

El código, los comentarios y los mensajes están **en castellano**. Es una decisión tomada y no va
a cambiar: quien mantiene esto piensa en castellano, y traducir a medias produce código donde
ninguna de las dos versiones se lee bien.

## Antes de mandar un pull request

- [ ] Los tests que tocan lo que cambiaste están en verde.
- [ ] Si arreglaste un bug, hay un test nuevo que lo cubre.
- [ ] No hay claves, tokens ni rutas personales en el diff.
- [ ] Los comentarios explican por qué, no qué.
