#!/usr/bin/env python3
"""Prepara o fundo da entrada do Prepacoin.

O original tem 1,4 MB em PNG, o que é peso a mais para uma imagem
decorativa que mil formandos vão abrir ao mesmo tempo. Sai em WebP, com
JPEG de reserva.

Produz também uma versão estreita para telemóvel: em ecrã de 400px de
largura, a imagem larga é reduzida ao ponto de as formas laterais
desaparecerem, e paga-se largura de banda por píxeis que ninguém vê. A
versão de telemóvel recorta a faixa central, que é a parte escura onde o
cartão assenta.
"""

import pathlib
from PIL import Image

RAIZ = pathlib.Path(__file__).resolve().parent.parent
ORIGINAL = pathlib.Path(
    r"C:/Users/devel/Downloads/ChatGPT Image 5 de set. de 2026, 14_46_13.png")


def main():
    if not ORIGINAL.is_file():
        raise SystemExit(f'não encontro o original: {ORIGINAL}')

    destino = RAIZ / 'web' / 'marca'
    destino.mkdir(parents=True, exist_ok=True)

    im = Image.open(ORIGINAL).convert('RGB')
    print('original', im.size, f'{ORIGINAL.stat().st_size/1024:.0f} KB')

    largo = destino / 'fundo-entrada.webp'
    im.save(largo, 'WEBP', quality=86, method=6)
    print(f'escrito web/marca/fundo-entrada.webp  {largo.stat().st_size/1024:.0f} KB')

    reserva = destino / 'fundo-entrada.jpg'
    im.save(reserva, 'JPEG', quality=84, optimize=True, progressive=True)
    print(f'escrito web/marca/fundo-entrada.jpg   {reserva.stat().st_size/1024:.0f} KB')

    # telemóvel: recorta a faixa central (a zona escura) num formato de
    # retrato, e reduz. As formas das pontas não cabiam de qualquer modo.
    w, h = im.size
    largura_alvo = int(h * 0.62)              # retrato aproximado
    x0 = (w - largura_alvo) // 2
    estreito = im.crop((x0, 0, x0 + largura_alvo, h))
    estreito = estreito.resize((720, int(720 * h / largura_alvo)), Image.LANCZOS)

    movel = destino / 'fundo-entrada-movel.webp'
    estreito.save(movel, 'WEBP', quality=84, method=6)
    print(f'escrito web/marca/fundo-entrada-movel.webp {estreito.size} '
          f'{movel.stat().st_size/1024:.0f} KB')


if __name__ == '__main__':
    main()
