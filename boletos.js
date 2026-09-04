// Prepacoin — boletos: pagar por entidade+referência, listar e cancelar.
//
// O fluxo de pagamento é o do projeto original: escrever a entidade e a
// referência, CONFIRMAR o que se vai pagar, e só depois pagar. O dígito
// de controlo da referência é validado no servidor antes sequer de se ir
// à base, por isso um engano na digitação é apanhado logo.

const areaLogin = document.getElementById('area-login');
const areaBoletos = document.getElementById('area-boletos');
const navLogado = document.getElementById('nav-logado');
const msgGeral = document.getElementById('msg-geral');

let listaAtual = 'a_pagar';
let dados = { a_pagar: [], emitidos: [] };
let consultado = null;

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function badgeBoleto(estado, vencido) {
  if (estado === 'por_pagar' && vencido) return '<span class="badge badge-rejeitada">Vencido</span>';
  const mapa = {
    por_pagar: ['badge-pendente', 'Por pagar'],
    em_pagamento: ['badge-pendente', 'A aguardar aprovação'],
    pago: ['badge-concluida', 'Pago'],
    cancelado: ['badge-rejeitada', 'Cancelado'],
  };
  const [c, t] = mapa[estado] || ['badge-rejeitada', estado];
  return `<span class="badge ${c}">${t}</span>`;
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

  alvo.innerHTML = lista.map((b) => `
    <div class="movimento">
      <div>
        <div class="mov-categoria">
          ${esc(b.descricao || 'Sem descrição')} ${badgeBoleto(b.estado, b.vencido)}
        </div>
        <div class="mov-detalhe">
          ${souEmitente ? 'a cargo de' : 'de'} ${esc(b.contraparte)} ·
          <span class="linha-mb">${esc(b.linha)}</span> ·
          ${b.vencido ? '<span class="vencido">prazo ultrapassado</span>'
                      : 'vence ' + formatarData(b.prazo)}
        </div>
      </div>
      <div style="text-align:right">
        <div class="mov-valor">${formatarP$(b.valor)}</div>
        <div class="fila" style="justify-content:flex-end; margin-top:0.35rem">
          <a class="codigo-auth" href="documento.html?boleto=${encodeURIComponent(b.entidade + '-' + b.referencia)}"
             target="_blank" rel="noopener">boleto</a>
          ${b.estado === 'pago'
            ? `<a class="codigo-auth" href="documento.html?comprovante=${encodeURIComponent(b.fatura)}"
                  target="_blank" rel="noopener">comprovativo</a>` : ''}
          ${souEmitente && b.estado === 'por_pagar'
            ? `<button type="button" class="perigo" style="margin:0;padding:0.25rem 0.7rem;font-size:0.78rem"
                       data-cancelar="${esc(b.referencia)}">Cancelar</button>` : ''}
        </div>
      </div>
    </div>`).join('');

  alvo.querySelectorAll('[data-cancelar]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      if (!confirm('Cancelar este boleto? Quem o recebeu deixa de o poder pagar.')) return;
      btn.disabled = true;
      const r = await api('banco_cancelar_boleto', { p_referencia: btn.dataset.cancelar });
      btn.disabled = false;
      mostrarMsg(msgGeral, r.ok ? 'Boleto cancelado.' : r.erro, r.ok ? 'sucesso' : 'erro');
      if (r.ok) carregar();
    });
  });
}

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
  areaLogin.hidden = true;
  areaBoletos.hidden = false;
  navLogado.hidden = false;
  await carregar();
}

document.getElementById('form-login').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const { error } = await sb.auth.signInWithPassword({
    email: document.getElementById('email').value,
    password: document.getElementById('senha').value,
  });
  if (error) {
    mostrarMsg(document.getElementById('msg-login'), 'Login inválido.', 'erro');
    return;
  }
  await verificarSessao();
});

document.getElementById('btn-sair').addEventListener('click', async () => {
  await sb.auth.signOut();
  window.location.reload();
});

verificarSessao();
