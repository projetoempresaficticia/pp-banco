#!/usr/bin/env python3
"""Escreve o esqueleto comum das páginas do Prepacoin.

O <head>, o ecrã de entrada, o rail e a barra de topo são iguais nas sete
páginas. Escritos à mão ficavam diferentes uns dos outros, que foi
exatamente o que aconteceu antes: cada ecrã tinha a sua navegação, com
links diferentes. Aqui saem todos do mesmo sítio.

Este script gera o ficheiro; o miolo de cada página vem de um dicionário
em `PAGINAS`, mais abaixo, e é a única coisa que muda entre elas.
"""

import pathlib

RAIZ = pathlib.Path(__file__).resolve().parent.parent

CABECA = '''<!DOCTYPE html>
<html lang="pt-PT">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>{titulo_aba}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Sora:wght@600;700&display=swap" />
  <link rel="stylesheet" href="web/biblioteca/prepacoin.css?v=CSS" />{estilo}
</head>
<body>

  <!-- entrada: quem chega aqui sem sessão entra e fica nesta página -->
  <div id="area-login" class="ecra-entrada">
    <div class="entrada-caixa">
      <div class="entrada-marca" aria-hidden="true">P$</div>
      <h1>Prepacoin</h1>
      <p class="sub">{sub_entrada}</p>
      <form id="form-login" class="painel">
        <label for="email">Email de login</label>
        <input id="email" type="email" autocomplete="username" required />
        <label for="senha">Senha</label>
        <input id="senha" type="password" autocomplete="current-password" required />
        <button type="submit">Entrar</button>
        <p class="msg" id="msg-login"></p>
      </form>
    </div>
  </div>

  <div class="app" id="app" hidden>
    <nav id="rail"></nav>
    <div class="painel-principal">
      <header id="barra"></header>
      <main>
{miolo}
      </main>
    </div>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="https://projetoempresaficticia.github.io/pp-base/web/comum.js"></script>
  <script src="web/comum-banco.js?v=COMUM"></script>
  <script src="web/tema.js?v=TEMA"></script>
  <script src="web/parcial.js?v=PARCIAL"></script>
  <script src="{script}?v=PAG"></script>
</body>
</html>
'''


def escrever(nome, titulo_aba, sub_entrada, miolo, script, estilo=''):
    if estilo:
        estilo = '\n  <style>\n' + estilo.rstrip() + '\n  </style>'
    html = CABECA.format(
        titulo_aba=titulo_aba, sub_entrada=sub_entrada,
        miolo=miolo.rstrip(), script=script, estilo=estilo,
    )
    (RAIZ / nome).write_text(html, encoding='utf-8')
    print('escrito', nome)
