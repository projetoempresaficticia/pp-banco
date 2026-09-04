// Prepacoin — boletos: pagar por entidade+referência, listar e cancelar.
//
// O fluxo de pagamento é o do projeto original: escrever a entidade e a
// referência, CONFIRMAR o que se vai pagar, e só depois pagar. O dígito
// de controlo da referência é validado no servidor antes sequer de se ir
// à base, por isso um engano na digitação é apanhado logo.

const msgGeral = document.getElementById('msg-geral');

let listaAtual = 'a_pagar';
let dados = { a_pagar: [], emitidos: [] };
let consultado = null;

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Um boleto tem um estado a mais do que a tabela geral: "vencido" não é
// um estado guardado, é um por_pagar cujo prazo já passou. Daí esta
// função em vez do `badgeEstado` comum.
//
// Ícone e palavra em todos, nunca só a cor: quem não distingue verde de
// vermelho tem de continuar a saber se pagou ou não.
function badgeBoleto(estado, vencido) {
  if (estado === 'por_pagar' && vencido) {
    return '<span class="badge badge-vencido"><span class="icone i-info"></span>Vencido</span>';
  }
  const mapa = {
    por_pagar:    ['badge-pendente',  'i-info',     'Por pagar'],
    em_pagamento: ['badge-pendente',  'i-info',     'À espera de aprovação'],
    pago:         ['badge-concluida', 'i-aprovado', 'Pago'],
    cancelado:    ['badge-cancelado', 'i-info',     'Cancelado'],
  };
  const [c, ic, t] = mapa[estado] || ['badge-rejeitada', 'i-info', estado];
  return `<span class="badge ${c}"><span class="icone ${ic}"></span>${t}</span>`;
}

// ---- consultar antes de pagar ----------------------------------------
document.getElementById('form-consultar').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const msg = document.getElementById('msg-consulta');
  const ent = document.getElementById('entidade').value;
  const ref = document.getElementById('referencia').value;

  mostrarMsg(msg, 'A consultar…');
  document.getElementById('painel-confirmar').hidden = true;

  const r = await api('banco_consultar_boleto', { p_entidade: ent, p_referencia: ref });
  if (!r.ok) {
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }
  mostrarMsg(msg, '');
  consultado = r.dados;

  document.getElementById('c-emitente').textContent = r.dados.emitente;
  document.getElementById('c-detalhe').innerHTML =
    `${esc(r.dados.descricao || 'Sem descrição')} · fatura ${esc(r.dados.fatura)}<br />` +
    `<span class="linha-mb">${esc(r.dados.linha)}</span> · vencimento ${formatarData(r.dados.prazo)}` +
    (r.dados.vencido ? ' <span class="vencido">(vencido)</span>' : '');
  document.getElementById('c-valor').textContent = formatarP$(r.dados.valor);

  const linhas = r.dados.linhas || [];
  document.getElementById('c-linhas').innerHTML = linhas.length
    ? linhas.map((l) => `
        <div class="movimento" style="padding:0.5rem 0">
          <div class="mov-detalhe">${esc(l.descricao)} × ${l.quantidade}</div>
          <div class="mov-detalhe">${formatarP$(l.total)}</div>
        </div>`).join('')
    : '';

  document.getElementById('painel-confirmar').hidden = false;
});

document.getElementById('btn-cancelar-pag').addEventListener('click', () => {
  document.getElementById('painel-confirmar').hidden = true;
  consultado = null;
});

document.getElementById('btn-confirmar-pag').addEventListener('click', async (ev) => {
  if (!consultado) return;
  const msg = document.getElementById('msg-pagamento');
  ev.target.disabled = true;
  mostrarMsg(msg, 'A pagar…');

  const r = await api('banco_pagar_referencia', {
    p_entidade: consultado.entidade, p_referencia: consultado.referencia,
  });
  ev.target.disabled = false;

  if (!r.ok) {
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }
  if (r.dados.estado === 'em_pagamento') {
    mostrarMsg(msg, r.dados.aviso, 'aviso');
  } else {
    mostrarMsg(msg,
      `Pago a ${r.dados.emitente}. Comprovativo ${r.dados.codigo}.`, 'sucesso');
  }
  document.getElementById('painel-confirmar').hidden = true;
  document.getElementById('entidade').value = '';
  document.getElementById('referencia').value = '';
  consultado = null;
  carregar();
});

// ---- listas ----------------------------------------------------------
document.querySelectorAll('.aba').forEach((b) => {
  b.addEventListener('click', () => {
    listaAtual = b.dataset.lista;
    document.querySelectorAll('.aba').forEach((o) =>
      o.setAttribute('aria-selected', String(o === b)));
    desenhar();
  });
});

function desenhar() {
  const alvo = document.getElementById('lista-boletos');
  const lista = dados[listaAtual] || [];
  const souEmitente = listaAtual === 'emitidos';

  if (!lista.length) {
    alvo.innerHTML = `<p class="vazio">${souEmitente
      ? 'Ainda não emitiu nenhum boleto.'
      : 'Não tem boletos por pagar.'}</p>`;
    return;
  }

  alvo.innerHTML = `
    <div class="rolavel">
      <table class="tabela">
        <thead>
          <tr>
            <th>Cobrança</th>
            <th>${souEmitente ? 'A cargo de' : 'De'}</th>
            <th>Referência</th>
            <th>Prazo</th>
            <th class="num">Valor</th>
            <th class="num">Documentos</th>
          </tr>
        </thead>
        <tbody>
          ${lista.map((b) => `
            <tr>
              <td>
                <div class="mov-categoria">${esc(b.descricao || 'Sem descrição')}</div>
                <div class="mov-detalhe">
                  ${b.avulso ? 'Boleto avulso' : 'Fatura ' + esc(b.fatura)}
                  · ${badgeBoleto(b.estado, b.vencido)}
                </div>
              </td>
              <td>${esc(b.contraparte)}</td>
              <td><span class="linha-mb">${esc(b.linha)}</span></td>
              <td>${b.vencido
                    ? '<span class="vencido">prazo ultrapassado</span>'
                    : formatarData(b.prazo)}</td>
              <td class="num"><strong>${formatarP$(b.valor)}</strong></td>
              <td class="num">
                <div class="fila" style="justify-content:flex-end">
                  <button type="button" class="fantasma"
                          data-ver-boleto="${esc(b.entidade + '-' + b.referencia)}">Boleto</button>
                  ${b.estado === 'pago'
                    ? `<button type="button" class="fantasma"
                               data-ver-comprovante="${esc(b.fatura)}">Comprovativo</button>` : ''}
                  ${souEmitente && b.estado === 'por_pagar'
                    ? `<button type="button" class="fantasma" style="color:var(--pc-erro)"
                               data-cancelar="${esc(b.referencia)}">Cancelar</button>` : ''}
                </div>
              </td>
            </tr>`).join('')}
        </tbody>
      </table>
    </div>`;

  // documentos numa janela por cima, sem sair da página
  alvo.querySelectorAll('[data-ver-boleto]').forEach((btn) => {
    btn.addEventListener('click', () => pcAbrirDocumento({ boleto: btn.dataset.verBoleto }));
  });
  alvo.querySelectorAll('[data-ver-comprovante]').forEach((btn) => {
    btn.addEventListener('click', () => pcAbrirDocumento({ comprovante: btn.dataset.verComprovante }));
  });

  alvo.querySelectorAll('[data-cancelar]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      if (!confirm('Cancelar este boleto? Quem o recebeu deixa de o poder pagar.')) return;
      btn.disabled = true;
      const r = await api('banco_cancelar_boleto', { p_referencia: btn.dataset.cancelar });
      btn.disabled = false;
      mostrarMsg(msgGeral, r.ok ? 'Boleto cancelado.' : r.erro, r.ok ? 'ok' : 'erro');
      if (r.ok) carregar();
    });
  });
}

/* ── emitir um boleto avulso ──────────────────────────────────────────
   Fatura e boleto são coisas diferentes, e até agora só se podia criar
   um boleto emitindo uma fatura com linhas. Uma taxa de P$ 15 não
   precisa de discriminação nenhuma: precisa de quem paga, do que é, do
   valor e do prazo.
   ─────────────────────────────────────────────────────────────────── */

async function abrirEmitirBoleto() {
  const dir = await api('id_diretorio', { p_com_conta: true });
  if (!dir.ok) { mostrarMsg(msgGeral, dir.erro, 'erro'); return; }

  const minha = dados.cedula;
  const opcoes = dir.dados
    .filter((e) => e.cedula !== minha)
    .map((e) => `<option value="${esc(e.cedula)}">${esc(e.nome)} · ${esc(e.cedula)}</option>`)
    .join('');

  if (!opcoes) {
    mostrarMsg(msgGeral, 'Não há outras entidades com conta aberta para cobrar.', 'erro');
    return;
  }

  const d = pcAbrirJanela('Emitir boleto',
    `<p class="suave" style="margin-top:0">
       Uma cobrança direta, sem fatura discriminada. Para cobrar item a
       item, use <a href="emitir.html">Emitir fatura</a>.
     </p>
     <form id="form-boleto">
       <label for="b-devedor">Quem tem de pagar</label>
       <select id="b-devedor" required>${opcoes}</select>

       <label for="b-descricao">Para que é a cobrança</label>
       <input id="b-descricao" type="text" placeholder="Taxa de registo" required />

       <div class="grade grade-2" style="margin-top:var(--pc-e4)">
         <div>
           <label for="b-valor" style="margin-top:0">Valor</label>
           <input id="b-valor" inputmode="decimal" placeholder="0,00" required />
           <p class="ajuda">Em P$, por exemplo 15,00.</p>
         </div>
         <div>
           <label for="b-dias" style="margin-top:0">Prazo (dias)</label>
           <input id="b-dias" type="number" min="1" max="365" value="30" />
         </div>
       </div>
       <p class="msg" id="msg-boleto"></p>
     </form>`,
    `<button type="button" class="secundario" id="b-cancelar">Desistir</button>
     <button type="button" id="b-emitir">
       <span class="icone i-recibo"></span>Emitir boleto
     </button>`);

  document.getElementById('b-cancelar').onclick = () => d.close();

  document.getElementById('b-emitir').onclick = async () => {
    const msg = document.getElementById('msg-boleto');
    const btn = document.getElementById('b-emitir');
    const valor = paraCentimos(document.getElementById('b-valor').value);

    if (!document.getElementById('b-descricao').value.trim()) {
      mostrarMsg(msg, 'Escreva para que serve a cobrança.', 'erro'); return;
    }
    if (valor === null || valor <= 0) {
      mostrarMsg(msg, 'Valor inválido. Use por exemplo 15,00.', 'erro'); return;
    }

    btn.disabled = true;
    mostrarMsg(msg, 'A emitir…');
    const r = await api('banco_emitir_boleto', {
      p_devedor: document.getElementById('b-devedor').value,
      p_descricao: document.getElementById('b-descricao').value.trim(),
      p_valor: valor,
      p_dias: parseInt(document.getElementById('b-dias').value, 10) || 30,
    });
    btn.disabled = false;

    if (!r.ok) { mostrarMsg(msg, r.erro, 'erro'); return; }

    d.close();
    mostrarMsg(msgGeral,
      `Boleto emitido. Entidade ${r.dados.entidade}, referência ${r.dados.referencia}.`, 'ok');
    await carregar();
    // mostrar logo o papel, que é o que se entrega a quem tem de pagar
    pcAbrirDocumento({ boleto: r.dados.entidade + '-' + r.dados.referencia });
  };
}

document.getElementById('btn-emitir-boleto').addEventListener('click', abrirEmitirBoleto);

async function carregar() {
  const r = await api('banco_boletos', {});
  if (!r.ok) {
    mostrarMsg(msgGeral, r.erro, 'erro');
    return;
  }
  dados = r.dados;
  desenhar();
}

async function verificarSessao() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return;
  pcMostrarApp('Boletos');
  await carregar();
}

pcLigarEntrada(verificarSessao);
verificarSessao();
