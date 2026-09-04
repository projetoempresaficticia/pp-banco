// Prepacoin — o documento imprimível: boleto ou comprovativo.
//
//   documento.html?boleto=<entidade>-<referencia>
//   documento.html?comprovante=<numero da fatura>
//
// O PDF sai pelo "Imprimir → Guardar como PDF" do browser. No projeto
// original o PDF era gerado no Google Drive; aqui não há Drive, e uma
// folha desenhada em CSS dá o mesmo resultado sem carregar biblioteca
// nenhuma — e o que se vê no ecrã é exatamente o que sai no papel.

const folha = document.getElementById('folha');

// Quando esta página é aberta dentro da janela de outra (num iframe),
// esconde a sua própria barra: quem manda são os botões da janela, e
// dois pares de "Voltar / Imprimir" ao mesmo tempo confundem.
const dentroDeJanela = window.self !== window.top;
if (dentroDeJanela) {
  const barra = document.querySelector('.barra-acoes');
  if (barra) barra.hidden = true;
  document.body.classList.add('em-janela');
} else {
  document.getElementById('btn-imprimir')
    .addEventListener('click', () => window.print());
}

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function linhaTab(rotulo, valor) {
  return `<tr><td class="rot">${esc(rotulo)}</td><td>${valor}</td></tr>`;
}

// Barras decorativas derivadas dos próprios dígitos, como no original.
// Não é um código de barras real: o pagamento faz-se escrevendo a
// entidade e a referência — e o documento diz isso ao leitor.
function barras(digitos) {
  let html = '';
  for (const c of String(digitos)) {
    const d = Number(c);
    const largura = 1 + (d % 3);
    const espaco = 1 + ((d + 1) % 3);
    html += `<i style="width:${largura}px;background:#1A1C21"></i>`;
    html += `<i style="width:${espaco}px;background:#fff"></i>`;
  }
  return `<div class="barras">${html}</div>`;
}

function topo(titulo, id) {
  return `
    <div class="doc-topo">
      <div>
        <div class="doc-marca">BANCO PREPACOIN</div>
        <div class="ref-rot" style="margin-top:2px">Prepara Portugal</div>
      </div>
      <div class="doc-id">${esc(id)}</div>
    </div>
    <h1 class="doc-titulo">${esc(titulo)}</h1>`;
}

const RODAPE = `
  <p class="rodape-doc">
    Documento fictício, gerado para fins pedagógicos — Prepara Portugal ·
    Laboratório de Práticas Administrativas. O código de barras é ilustrativo:
    o pagamento faz-se escrevendo a entidade e a referência no Prepacoin.
  </p>`;

function tabelaLinhas(linhas, total) {
  if (!linhas || !linhas.length) return '';
  return `
    <table class="linhas-fatura">
      <thead>
        <tr><th>Descrição</th><th class="num">Qt.</th><th class="num">Unitário</th><th class="num">Total</th></tr>
      </thead>
      <tbody>
        ${linhas.map((l) => `
          <tr>
            <td>${esc(l.descricao)}</td>
            <td class="num">${l.quantidade}</td>
            <td class="num">${formatarP$(l.valor_unitario)}</td>
            <td class="num">${formatarP$(l.total)}</td>
          </tr>`).join('')}
        <tr>
          <td colspan="3" class="num total-linha">Total</td>
          <td class="num total-linha">${formatarP$(total)}</td>
        </tr>
      </tbody>
    </table>`;
}

const ROTULO_ESTADO = {
  por_pagar: 'Por pagar',
  em_pagamento: 'À espera de aprovação interna',
  pago: 'Pago',
  cancelado: 'Cancelado pelo emitente',
};

async function mostrarBoleto(entidade, referencia) {
  // `banco_boleto_documento`, não `banco_consultar_boleto`: esta serve as
  // duas partes e continua a servir depois de pago, que é o que um
  // documento imprimível precisa.
  const r = await api('banco_boleto_documento', {
    p_entidade: entidade, p_referencia: referencia,
  });
  if (!r.ok) {
    folha.innerHTML = topo('Boleto', '—') + `<p class="msg erro">${esc(r.erro)}</p>`;
    return;
  }
  const d = r.dados;

  const dig = d.entidade + d.referencia;

  // Fatura e boleto são coisas diferentes, e o papel tem de dizer qual
  // é qual. Um boleto avulso não tem fatura discriminada por trás, e
  // imprimir "Fatura FT-…" no cabeçalho dele seria mentira.
  const titulo = d.avulso
    ? 'Boleto de cobrança'
    : 'Referência para pagamento de serviços';
  const identificador = d.avulso
    ? 'Boleto ' + esc(d.entidade) + '/' + esc(d.referencia)
    : 'Fatura ' + (d.fatura || '');

  folha.innerHTML =
    topo(titulo, identificador) +
    `<table class="doc">
      ${linhaTab('Emitente', `${esc(d.emitente)} · ${esc(d.emitente_cedula)}`)}
      ${linhaTab('A cargo de', `${esc(d.devedor)} · ${esc(d.devedor_cedula)}`)}
      ${linhaTab('Descrição', esc(d.descricao || '—'))}
      ${linhaTab('Vencimento', formatarData(d.prazo) +
         (d.vencido ? ' <strong style="color:var(--pc-erro)">(vencido)</strong>' : ''))}
      ${linhaTab('Estado', d.estado === 'pago'
         ? `<strong style="color:var(--pc-ok)">Pago em ${formatarDataHora(d.pago_em)}</strong>`
         : esc(ROTULO_ESTADO[d.estado] || d.estado))}
    </table>

    <div class="caixa-ref">
      <div class="ref-grade">
        <div>
          <div class="ref-rot">Entidade</div>
          <div class="ref-val">${esc(d.entidade)}</div>
        </div>
        <div>
          <div class="ref-rot">Referência</div>
          <div class="ref-val">${esc(d.referencia.slice(0,3))} ${esc(d.referencia.slice(3,6))} ${esc(d.referencia.slice(6,9))}</div>
        </div>
        <div>
          <div class="ref-rot">Valor</div>
          <div class="ref-val valor">${formatarP$(d.valor)}</div>
        </div>
      </div>
      ${barras(dig)}
      <div class="linha-digitos">${esc(d.entidade)}&nbsp;&nbsp;${esc(d.referencia)}</div>
    </div>

    ${d.avulso ? '' : tabelaLinhas(d.linhas, d.valor)}
    ${RODAPE}`;
}

async function mostrarComprovante(numeroFatura) {
  const r = await api('banco_verificar_fatura', { p_numero: numeroFatura });
  if (!r.ok) {
    folha.innerHTML = topo('Comprovativo', '—') + `<p class="msg erro">${esc(r.erro)}</p>`;
    return;
  }
  const d = r.dados;
  folha.innerHTML =
    topo(d.paga ? 'Comprovativo de pagamento' : 'Fatura', d.numero) +
    (d.paga ? '' : '<p class="msg aviso">Esta fatura ainda não foi paga.</p>') +
    `<table class="doc">
      ${linhaTab('Fatura', esc(d.numero))}
      ${linhaTab('Emitente', esc(d.emitente || d.emitente_cedula))}
      ${linhaTab('A cargo de', esc(d.devedor_cedula))}
      ${linhaTab('Descrição', esc(d.descricao || '—'))}
      ${linhaTab('Emitida em', formatarDataHora(d.emitida_em))}
      ${d.paga ? linhaTab('Paga em', formatarDataHora(d.paga_em)) : ''}
      ${linhaTab('Referência', esc(d.referencia_boleto || '—'))}
      ${linhaTab('Estado', `<strong style="color:${d.paga ? 'var(--pc-ok)' : 'var(--pc-aviso)'}">${esc(d.estado)}</strong>`)}
    </table>
    ${tabelaLinhas(d.linhas, d.valor_total)}
    ${RODAPE}`;
}

(async () => {
  const p = new URLSearchParams(window.location.search);
  const boleto = p.get('boleto');
  const comprovante = p.get('comprovante');

  const { data } = await sb.auth.getSession();
  if (!data.session) {
    folha.innerHTML = topo('Documento', '—') +
      '<p class="msg erro">Precisa de entrar no Prepacoin para ver este documento.</p>' +
      '<a class="botao" href="index.html">Entrar</a>';
    return;
  }

  if (boleto) {
    const [ent, ref] = boleto.split('-');
    await mostrarBoleto(ent, ref);
  } else if (comprovante) {
    await mostrarComprovante(comprovante);
  } else {
    folha.innerHTML = topo('Documento', '—') +
      '<p class="msg erro">Indique um boleto ou um comprovativo.</p>';
  }
})().catch((e) => {
  // sem isto, um erro dentro do async deixava a folha em "A carregar…"
  // para sempre, sem dizer o que se passou
  folha.innerHTML = topo('Documento', '—') +
    '<p class="msg erro">Não foi possível montar o documento: ' + esc(e.message) + '</p>';
});
