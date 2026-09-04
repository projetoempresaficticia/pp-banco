#!/usr/bin/env python3
"""Reescreve os ?v= dos ficheiros locais com o sha1 do próprio ficheiro.

Porquê: durante os testes o browser serviu uma cópia velha do
comum-banco.js e o comprovativo ficou preso em "A carregar…" com um
`formatarDataHora is not defined` que não aparecia em lado nenhum. A
solução é marcar cada ficheiro com o resumo do seu conteúdo, para o
endereço mudar sempre que o conteúdo muda.

Fazer isso à mão em 8 páginas x 5 ficheiros falha. Este script trata de
tudo. Aceita marcadores por preencher (?v=CSS, ?v=APP, ...) e resumos
antigos, e substitui ambos.

Uso:
    python ferramentas/versoes.py            verifica e corrige
    python ferramentas/versoes.py --conferir só verifica, devolve 1 se
                                             houver algo desatualizado
"""

import hashlib
import pathlib
import re
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent

# só ficheiros locais: os CDN e as fontes não levam ?v=
PADRAO = re.compile(r'(?P<attr>src|href)="(?P<ficheiro>(?!https?:)[^"?]+)\?v=(?P<versao>[^"]*)"')


def resumo(caminho: pathlib.Path) -> str:
    return hashlib.sha1(caminho.read_bytes()).hexdigest()[:8]


def main() -> int:
    conferir = '--conferir' in sys.argv
    problemas = 0
    alterados = []

    for html in sorted(RAIZ.glob('*.html')):
        texto = html.read_text(encoding='utf-8')
        original = texto

        def troca(m: re.Match) -> str:
            nonlocal problemas
            alvo = (html.parent / m.group('ficheiro')).resolve()
            if not alvo.is_file():
                print(f'  FALTA    {html.name} -> {m.group("ficheiro")}')
                problemas += 1
                return m.group(0)
            novo = resumo(alvo)
            if novo != m.group('versao'):
                print(f'  {"desatualizado" if conferir else "corrigido"}'
                      f'  {html.name} -> {m.group("ficheiro")}  {m.group("versao")} -> {novo}')
                problemas += 1
            return f'{m.group("attr")}="{m.group("ficheiro")}?v={novo}"'

        texto = PADRAO.sub(troca, texto)
        if texto != original and not conferir:
            html.write_text(texto, encoding='utf-8')
            alterados.append(html.name)

    if problemas == 0:
        print('Todas as versões batem certo.')
        return 0
    if conferir:
        print(f'\n{problemas} por corrigir. Corra sem --conferir.')
        return 1
    print(f'\n{len(alterados)} ficheiros atualizados.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
