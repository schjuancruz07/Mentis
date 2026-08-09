# CAPABILITY: /corregir | corrige ortografía, gramática y puntuación de un texto (modelo de apoyo NVIDIA)
TEXTO="$1"
if [ -z "$TEXTO" ]; then
  printf 'Uso: /corregir <texto a corregir>'
  exit 0
fi
bash "$HOME/Mentis/engine/ask-nvidia.sh" reason "Corregí ortografía, gramática y puntuación del siguiente texto en español. No cambies el significado, el tono ni el registro, y no agregues comentarios. Respondé ÚNICAMENTE con el texto ya corregido, sin comillas ni explicaciones:

$TEXTO"
