# Dice si la imagen es predominantemente roja. Se usa desde el test de video: la ruta llega como
# ARGUMENTO y ya convertida a formato Windows (ERR-006/ERR-069).
import sys
try:
    from PIL import Image
except Exception:
    print("SIN-PIL"); raise SystemExit(0)
try:
    r, g, b = Image.open(sys.argv[1]).convert("RGB").resize((1, 1)).getpixel((0, 0))
except Exception:
    print("no"); raise SystemExit(0)
print("si" if r > 120 and b < 90 else "no")
