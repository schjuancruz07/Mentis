# Seguridad

## Cómo reportar un problema de seguridad

**No lo abras como issue público.** Un issue es visible para cualquiera, incluido quien quiera
aprovechar el problema antes de que esté arreglado.

Usá el reporte privado de GitHub:

1. Entrá a la pestaña **Security** del repositorio.
2. **Report a vulnerability**.
3. Contá qué encontraste y cómo reproducirlo.

Eso abre un canal privado entre vos y quien mantiene el proyecto.

**Qué esperar:** este es un proyecto personal, sin equipo ni guardia. Se lee y se responde, pero
no hay un tiempo comprometido. Si el problema es serio, decilo en el título.

## Qué versión se mantiene

La última publicada en `main`. No hay ramas de soporte de versiones viejas.

## Lo que Mentis puede hacer, por diseño

Antes de reportar algo como vulnerabilidad, vale saber qué es comportamiento esperado. Mentis es
un asistente que **corre comandos y modifica archivos en tu máquina**: eso es para lo que sirve,
no es una falla.

Lo que sí está pensado como barrera:

- Los comandos destructivos están bloqueados salvo que se habilite el modo sin frenos, a mano.
- Las capacidades invasivas (cámara, pantalla, control del mouse, teléfono) arrancan **apagadas** y
  se prenden de a una.
- La cámara tiene un tope de usos por turno, para que un error no pueda dejarla disparando sola.
- Las acciones delicadas piden permiso en una ventana antes de correr.
- Las claves y tokens se ocultan automáticamente antes de mandar texto a un modelo.

Si encontraste una forma de **saltar alguna de esas barreras**, eso sí es un problema de seguridad
y vale reportarlo.

## Lo que sí nos interesa mucho

- Que una clave, un token o una credencial termine en un lugar donde no debería: un log, el paquete
  de actualización, la copia para otra persona, o el repositorio.
- Que datos privados (conversaciones, memoria, archivos) salgan de la máquina sin que el usuario lo
  haya pedido.
- Que se pueda ejecutar código sin pasar por las barreras de arriba.
- Que una actualización pueda ser modificada por un tercero en el camino.

## Tus claves

Mentis guarda las claves de API en archivos locales (`engine/.nv-secrets`,
`.custom-models-secrets.env`, `mcp-bridge/.secrets.env`). Esos archivos:

- Nunca se versionan (están en `.gitignore`).
- No viajan en las actualizaciones ni en las copias para otras personas.
- Están excluidos por nombre en el proceso de publicación, que **falla** si detecta alguno.

Si encontrás alguna forma de que se escapen igual, es exactamente el tipo de cosa que hay que
reportar.
