#!/usr/bin/env python3
"""Prepara os ficheiros da marca do Prepacoin a partir do PNG original.

Porquê um script e não um recorte à mão: o PNG que veio do desenhista
tem 1270x1239 com transparência à volta, e o chip lá dentro tem
1041x1014. Meter isso num `<img>` de 40x40 dava a marca esticada, que foi
exatamente o que aconteceu com o ícone do Cartório. Aqui o recorte é
medido, e é repetível se o original mudar.

Produz:

  web/marca/prepacoin-marca.png   só a marca escura, em alfa. Vai como
                                  `mask-image` sobre o chip que o CSS
                                  desenha, por isso segue o currentColor
                                  e nunca traz um lima segundo.
  web/marca/prepacoin-512.png     o ícone inteiro, para partilha.
  apple-touch-icon.png            180x180, para o ecrã inicial do iOS.
  favicon-32.png / favicon.ico    o separador do browser.

DECISÃO DE COR: o lima do PNG original é #E2FA56, e o token da
biblioteca é #EBFF78 (do kit Nexus). São diferentes o suficiente para se
notar lado a lado. Os ficheiros compostos usam o TOKEN, para haver um só
lima em todo o produto. A tinta do original (#0A0A0E) e a do token
(#0A0C10) diferem 2/255 e são indistinguíveis.
"""

import pathlib
from PIL import Image

RAIZ = pathlib.Path(__file__).resolve().parent.parent
ORIGINAL = pathlib.Path(
    r"C:/Users/devel/Downloads/ChatGPT Image 4 de set. de 2026, 22_42_22.png")

LIMA = (235, 255, 120, 255)   # --pc-lima  #EBFF78
TINTA = (10, 12, 16, 255)     # --pc-tinta #0A0C10


def mascara_por_canal(im, teste_r=None, teste_g=None, teste_b=None, teste_a=None):
    """Máscara em L: 255 onde todos os testes dados passam."""
    canais = dict(zip('rgba', im.split()))
    saida = Image.new('L', im.size, 255)
    for nome, teste in (('r', teste_r), ('g', teste_g),
                        ('b', teste_b), ('a', teste_a)):
        if teste is None:
            continue
        m = Image.eval(canais[nome], lambda v, t=teste: 255 if t(v) else 0)
        saida = Image.composite(m, Image.new('L', im.size, 0), saida)
    return saida


def quadrado(caixa):
    """Alarga a caixa para ficar quadrada, sem esticar nada."""
    x0, y0, x1, y1 = caixa
    lado = max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    return (cx - lado // 2, cy - lado // 2, cx - lado // 2 + lado, cy - lado // 2 + lado)


def main():
    if not ORIGINAL.is_file():
        raise SystemExit(f'não encontro o original: {ORIGINAL}')

    im = Image.open(ORIGINAL).convert('RGBA')

    lima = mascara_por_canal(im, teste_g=lambda v: v > 200,
                             teste_b=lambda v: v < 170,
                             teste_r=lambda v: v > 150,
                             teste_a=lambda v: v > 200)
    tinta = mascara_por_canal(im, teste_r=lambda v: v < 90,
                              teste_g=lambda v: v < 90,
                              teste_b=lambda v: v < 90,
                              teste_a=lambda v: v > 200)

    # o chip é o lima MAIS a marca que está lá dentro
    chip = Image.composite(Image.new('L', im.size, 255), lima, tinta)
    caixa = quadrado(chip.getbbox())
    print('chip recortado em', caixa, '->', caixa[2] - caixa[0], 'px de lado')

    destino = RAIZ / 'web' / 'marca'
    destino.mkdir(parents=True, exist_ok=True)

    # ── 1. a marca sozinha, em alfa, para usar como máscara ──────────
    marca = tinta.crop(caixa).resize((512, 512), Image.LANCZOS)
    alfa = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
    alfa.putalpha(marca)
    alfa.save(destino / 'prepacoin-marca.png', optimize=True)
    print('escrito web/marca/prepacoin-marca.png')

    # ── 2. o ícone inteiro, com o lima do TOKEN ──────────────────────
    def compor(lado):
        base = Image.new('RGBA', (lado, lado), (0, 0, 0, 0))
        forma = chip.crop(caixa).resize((lado, lado), Image.LANCZOS)
        base.paste(Image.new('RGBA', (lado, lado), LIMA), (0, 0), forma)
        m = tinta.crop(caixa).resize((lado, lado), Image.LANCZOS)
        base.paste(Image.new('RGBA', (lado, lado), TINTA), (0, 0), m)
        return base

    compor(512).save(destino / 'prepacoin-512.png', optimize=True)
    print('escrito web/marca/prepacoin-512.png')

    compor(180).save(RAIZ / 'apple-touch-icon.png', optimize=True)
    print('escrito apple-touch-icon.png')

    compor(32).save(RAIZ / 'favicon-32.png', optimize=True)
    print('escrito favicon-32.png')

    compor(256).save(RAIZ / 'favicon.ico',
                     sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
    print('escrito favicon.ico')


if __name__ == '__main__':
    main()
