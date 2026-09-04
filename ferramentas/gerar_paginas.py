#!/usr/bin/env python3
"""Gera as páginas do Prepacoin que partilham o esqueleto.

Correr a partir da raiz do repositório:
    python ferramentas/gerar_paginas.py
    python ferramentas/versoes.py

O index.html e o biblioteca.html não passam por aqui: o primeiro tem um
painel de conta que não se parece com nenhum outro, o segundo é a
montra da biblioteca. Os outros cinco saem todos deste molde.
"""

import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from molde import escrever  # noqa: E402


# ── transferir ────────────────────────────────────────────────────────
escrever(
    'transferir.html',
    'Prepacoin — Transferir',
    'Entre para fazer uma transferência.',
    '''
        <div class="topo-pagina">
          <div>
            <h1>Nova transferência</h1>
            <p class="suave" style="margin:6px 0 0">
              O dinheiro sai da conta que escolher e entra no IBAN de destino.
            </p>
          </div>
        </div>

        <div class="grade grade-conta">
          <form id="form-transferir" class="painel">
            <label for="origem">De qual conta sai</label>
            <select id="origem" required></select>
            <p class="msg" id="info-origem"></p>

            <label for="destino">IBAN de destino</label>
            <input id="destino" placeholder="PT50 0000 0000 0000 0000 0000 0" required />
            <p class="ajuda">Pode escrever com ou sem espaços.</p>

            <label for="valor">Valor</label>
            <input id="valor" inputmode="decimal" placeholder="0,00" required />
            <p class="ajuda">Em P$, por exemplo 25,00.</p>

            <label for="categoria">Categoria</label>
            <select id="categoria" required>
              <option value="venda">Venda</option>
              <option value="salario">Salário</option>
              <option value="imposto">Imposto</option>
              <option value="renda">Renda</option>
              <option value="utilities">Utilities (água, energia, internet)</option>
              <option value="outro">Outro</option>
            </select>

            <label for="descricao">Descrição</label>
            <input id="descricao" placeholder="Referência do pagamento" />

            <!-- o botão fica separado do último campo por uma linha e por
                 espaço a sério: colado, parecia fazer parte da descrição -->
            <div class="acoes-fim">
              <button type="submit" id="btn-transferir">
                <span class="icone i-transferir"></span>Transferir
              </button>
            </div>
            <p class="msg" id="msg-transferir"></p>
          </form>

          <div>
            <div class="painel">
              <div class="painel-cabeca"><h3>Antes de confirmar</h3></div>
              <p class="suave" style="font-size:13px">
                Salário, imposto, renda e utilities são <strong>obrigações</strong>.
                Se a conta não tiver saldo para uma delas, a empresa fica marcada
                em incumprimento, e isso aparece a quem consultar a certidão no
                Cartório.
              </p>
              <p class="suave" style="font-size:13px">
                Uma venda sem saldo é apenas recusada e fica no extrato como
                rejeitada. Um erro a escrever não leva ninguém à falência.
              </p>
            </div>
            <div class="painel">
              <div class="painel-cabeca"><h3>Acima do limite</h3></div>
              <p class="suave" style="font-size:13px">
                Uma transferência acima do limite de aprovação da conta não sai
                logo: fica pendente até um gerente a aprovar, e o valor já conta
                como preso no saldo disponível.
              </p>
            </div>
          </div>
        </div>
''',
    'transferir.js',
)


# ── boletos ───────────────────────────────────────────────────────────
escrever(
    'boletos.html',
    'Prepacoin — Boletos',
    'Entre para pagar ou emitir boletos.',
    '''
        <div class="topo-pagina">
          <div>
            <h1>Boletos</h1>
            <p class="suave" style="margin:6px 0 0">
              Pague escrevendo a entidade e a referência, como num homebanking.
            </p>
          </div>
          <div class="fila">
            <a href="emitir.html" class="botao secundario">
              <span class="icone i-cartao"></span>Emitir fatura
            </a>
            <button type="button" id="btn-emitir-boleto">
              <span class="icone i-recibo"></span>Emitir boleto
            </button>
          </div>
        </div>

        <p class="suave" style="font-size:13px; margin:-8px 0 var(--pc-e5)">
          Uma <strong>fatura</strong> discrimina o que está a cobrar, item a
          item, e gera o boleto. Um <strong>boleto</strong> é a ordem de
          pagamento: entidade, referência, valor e prazo. Para cobrar uma taxa
          ou um acerto não é preciso fatura nenhuma.
        </p>

        <div class="painel">
          <div class="painel-cabeca"><h3>Pagar um boleto</h3></div>
          <p class="suave" style="font-size:13px; margin-top:0">
            Escreva a entidade e a referência que constam do boleto. Mostra-se
            o que vai pagar antes de o dinheiro sair.
          </p>
          <form id="form-consultar" class="campos-ref">
            <div class="entidade">
              <label for="entidade">Entidade</label>
              <input id="entidade" class="ref mono" inputmode="numeric" maxlength="5"
                     placeholder="20009" required />
            </div>
            <div class="referencia">
              <label for="referencia">Referência</label>
              <input id="referencia" class="ref mono" inputmode="numeric" maxlength="11"
                     placeholder="937 456 155" required />
            </div>
            <button type="submit">
              <span class="icone i-procurar"></span>Consultar
            </button>
          </form>
          <p class="msg" id="msg-consulta"></p>

          <div id="painel-confirmar" class="painel"
               style="margin-top:var(--pc-e4); background:var(--pc-chao-suave)" hidden>
            <h3 style="margin-top:0" id="c-emitente">—</h3>
            <div id="c-detalhe" class="msg" style="margin-top:0"></div>
            <div id="c-linhas" style="margin-top:var(--pc-e3)"></div>
            <div class="topo-pagina" style="margin:var(--pc-e4) 0 0">
              <div>
                <div class="rotulo-secao">Total a pagar</div>
                <div class="numero" style="font-family:Sora,sans-serif; font-size:26px; font-weight:700" id="c-valor">—</div>
              </div>
              <div class="fila">
                <button type="button" class="secundario" id="btn-cancelar-pag">Desistir</button>
                <button type="button" id="btn-confirmar-pag">Confirmar pagamento</button>
              </div>
            </div>
            <p class="msg" id="msg-pagamento"></p>
          </div>
        </div>

        <div class="abas" role="tablist" style="margin-top:var(--pc-e6)">
          <button class="aba" role="tab" aria-selected="true" data-lista="a_pagar">A pagar</button>
          <button class="aba" role="tab" aria-selected="false" data-lista="emitidos">Emitidos por mim</button>
        </div>

        <div class="painel">
          <div id="lista-boletos"><p class="vazio">A carregar…</p></div>
        </div>

        <p class="msg" id="msg-geral"></p>
''',
    'boletos.js',
    estilo='''    .campos-ref { display: flex; gap: var(--pc-e3); align-items: flex-end; flex-wrap: wrap; }
    .campos-ref .entidade { max-width: 130px; }
    .campos-ref .referencia { max-width: 220px; }
    .campos-ref label { margin-top: 0; }
    input.ref { font-size: 16px; letter-spacing: 2px; }''',
)


# ── emitir ────────────────────────────────────────────────────────────
escrever(
    'emitir.html',
    'Prepacoin — Emitir fatura',
    'Entre para emitir uma fatura.',
    '''
        <div id="area-emitir" hidden>
          <div class="topo-pagina">
            <div>
              <h1>Emitir fatura</h1>
              <p class="suave" style="margin:6px 0 0">
                A fatura diz o que está a cobrar. O boleto é a referência com que
                o cliente paga, e sai dela automaticamente.
              </p>
            </div>
          </div>

          <form id="form-emitir" class="painel">
            <label for="devedor">A quem vai faturar</label>
            <select id="devedor" required></select>
            <p class="ajuda">Só aparecem entidades com conta aberta no Prepacoin.</p>

            <label for="descricao">Descrição da fatura</label>
            <input id="descricao" type="text" placeholder="Encomenda de setembro" required />

            <h3 style="margin-top:var(--pc-e5)">Itens</h3>
            <div id="itens"></div>
            <button type="button" class="secundario" id="btn-add-item">
              <span class="icone icone-16 i-mais"></span>Acrescentar item
            </button>

            <div class="total-caixa">
              <div>
                <div class="rotulo-secao">Total</div>
                <div class="total-valor numero" id="total">P$ 0,00</div>
              </div>
              <div>
                <label for="dias" style="margin-top:0">Prazo (dias)</label>
                <input id="dias" type="number" min="1" max="365" value="30" style="width:110px" />
              </div>
            </div>

            <div class="acoes-fim">
              <button type="submit" id="btn-emitir">
                <span class="icone i-recibo"></span>Emitir fatura e boleto
              </button>
            </div>
            <p class="msg" id="msg-emitir"></p>
          </form>
        </div>

        <div id="area-resultado" class="painel" hidden>
          <div class="selo">
            <div class="selo-icone"><span class="icone icone-24 i-aprovado"></span></div>
            <div class="selo-titulo">Fatura emitida</div>
            <div class="selo-subtitulo" id="r-sub">—</div>
            <div class="selo-grade">
              <div class="selo-campo"><div class="rotulo">Fatura</div><div class="valor" id="r-fatura">—</div></div>
              <div class="selo-campo"><div class="rotulo">Total</div><div class="valor" id="r-total">—</div></div>
              <div class="selo-campo"><div class="rotulo">Entidade</div><div class="valor" id="r-entidade">—</div></div>
              <div class="selo-campo"><div class="rotulo">Referência</div><div class="valor" id="r-referencia">—</div></div>
            </div>
            <div class="fila" style="justify-content:center; margin-top:var(--pc-e5)">
              <button type="button" id="btn-ver-boleto">
                <span class="icone i-exportar"></span>Ver e imprimir o boleto
              </button>
              <a class="botao secundario" href="boletos.html">Ver boletos</a>
              <button type="button" class="secundario" id="btn-nova">Emitir outra</button>
            </div>
          </div>
        </div>

        <div id="area-sem-empresa" class="painel" hidden style="max-width:520px">
          <h2>Só empresas emitem faturas</h2>
          <p class="suave">
            A sua cédula não está vinculada a nenhuma empresa, e uma fatura é
            emitida sempre em nome de uma.
          </p>
        </div>
''',
    'emitir.js',
    estilo='''    .linha-item {
      display: grid; grid-template-columns: 1fr 90px 150px 44px;
      gap: var(--pc-e3); align-items: end; margin-bottom: var(--pc-e3);
    }
    .linha-item label { margin-top: 0; }
    .linha-item .remover {
      background: none; border: 1px solid var(--pc-linha); color: var(--pc-erro);
      width: 44px; padding: 0; border-radius: var(--pc-r-controlo);
    }
    .linha-item .remover:hover { background: var(--pc-erro-fundo); }
    @media (max-width: 680px) { .linha-item { grid-template-columns: 1fr 1fr; } }
    .total-caixa {
      display: flex; justify-content: space-between; align-items: center;
      gap: var(--pc-e4); flex-wrap: wrap;
      border-top: 1px solid var(--pc-linha); margin-top: var(--pc-e5);
      padding-top: var(--pc-e4);
    }
    .total-valor { font-family: 'Sora', sans-serif; font-size: 30px; font-weight: 700; letter-spacing: -0.02em; }''',
)


# ── aprovações ────────────────────────────────────────────────────────
escrever(
    'aprovacoes.html',
    'Prepacoin — Aprovações',
    'Entre para ver as transferências à espera.',
    '''
        <div id="area-aprovacoes" hidden>
          <div class="topo-pagina">
            <div>
              <h1>Aprovações</h1>
              <p class="suave" style="margin:6px 0 0">
                Transferências acima do limite da conta ficam aqui até um gerente
                decidir. O saldo é revalidado no momento da aprovação.
              </p>
            </div>
          </div>

          <div class="painel">
            <div id="lista-pendentes"><p class="vazio">A carregar…</p></div>
          </div>

          <p class="msg" id="msg-aprovacoes"></p>
        </div>
''',
    'aprovacoes.js',
)


print('\nAgora: python ferramentas/versoes.py')
