// Prepacoin — emitir fatura com itens, e o boleto que sai dela.
//
// O total é somado aqui só para o utilizador ver enquanto escreve; quem
// manda é o servidor, que volta a somar a partir das linhas. Se os dois
// discordarem, é o do servidor que vale.

const areaEmitir = document.getElementById('area-emitir');
const areaResultado = document.getElementById('area-resultado');
const areaSemEmpresa = document.getElementById('area-sem-empresa');
const itens = document.getElementById('itens');

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function novoItem(descricao = '', qtd = 1, valor = '') {
  const div = document.createElement('div');
  div.className = 'linha-item';
  div.innerHTML = `
    <div>
      <label>Descrição</label>
      <input class="i-desc" type="text" value="${esc(descricao)}" placeholder="Ex.: Saco de farinha 25kg" required />
    </div>
    <div>
      <label>Qt.</label>
      <input class="i-qtd" type="number" min="1" value="${qtd}" required />
    </div>
    <div>
      <label>Preço unitário (P$)</label>
      <input class="i-valor" inputmode="decimal" value="${esc(valor)}" placeholder="0,00" required />
    </div>
    <button type="button" class="remover" title="Remover item">×</button>`;

  div.querySelector('.remover').addEventListener('click', () => {
    // nunca deixar a fatura sem nenhuma linha
    if (itens.children.length === 1) {
      div.querySelectorAll('input').forEach((i) => { i.value = i.classList.contains('i-qtd') ? 1 : ''; });
    } else {
      div.remove();
    }
    recalcular();
  });
  div.querySelectorAll('input').forEach((i) => i.addEventListener('input', recalcular));
  itens.appendChild(div);
}

function lerItens() {
  return Array.from(itens.children).map((d) => ({
    descricao: d.querySelector('.i-desc').value.trim(),
    quantidade: parseInt(d.querySelector('.i-qtd').value, 10) || 0,
    valor_unitario: paraCentimos(d.querySelector('.i-valor').value),
  }));
}

function recalcular() {
  const total = lerItens().reduce((soma, l) =>
    soma + (l.valor_unitario || 0) * (l.quantidade || 0), 0);
  document.getElementById('total').textContent = formatarP$(total);
}

document.getElementById('btn-add-item').addEventListener('click', () => novoItem());

// Quem pode receber a fatura: qualquer entidade com conta, exceto a minha.
//
// A lista tem de vir do `id_diretorio`, não de um select em `empresas`:
// a RLS — e bem — só devolve a ficha própria, por isso o select direto
// deixava esta caixa sempre vazia e ninguém conseguia faturar a ninguém.
async function carregarDevedores(minha) {
  const alvo = document.getElementById('devedor');
  const r = await api('id_diretorio', { p_com_conta: true });

  if (!r.ok) {
    alvo.innerHTML = `<option value="">— ${esc(r.erro)} —</option>`;
    return;
  }

  const opcoes = r.dados
    .filter((e) => e.cedula !== minha)
    .map((e) => `<option value="${esc(e.cedula)}">${esc(e.nome)} · ${esc(e.cedula)}</option>`);

  alvo.innerHTML = opcoes.length
    ? opcoes.join('')
    : '<option value="">— não há outras entidades com conta aberta —</option>';
}

async function minhaEmpresaCedula() {
  const { data } = await sb.auth.getUser();
  if (!data.user) return null;
  const { data: p } = await sb.from('pessoas').select('empresa_id').eq('id', data.user.id).single();
  if (!p || !p.empresa_id) return null;
  const { data: e } = await sb.from('empresas').select('cedula').eq('id', p.empresa_id).single();
  return e ? e.cedula : null;
}

document.getElementById('form-emitir').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const msg = document.getElementById('msg-emitir');
  const btn = document.getElementById('btn-emitir');

  const linhas = lerItens();
  if (linhas.some((l) => !l.descricao)) {
    mostrarMsg(msg, 'Todos os itens precisam de descrição.', 'erro');
    return;
  }
  if (linhas.some((l) => l.valor_unitario === null)) {
    mostrarMsg(msg, 'Há um preço inválido. Use por exemplo 25,00.', 'erro');
    return;
  }

  btn.disabled = true;
  mostrarMsg(msg, 'A emitir…');

  const r = await api('banco_emitir_fatura', {
    p_devedor: document.getElementById('devedor').value,
    p_descricao: document.getElementById('descricao').value.trim(),
    p_linhas: linhas,
    p_dias: parseInt(document.getElementById('dias').value, 10) || 30,
  });

  btn.disabled = false;
  if (!r.ok) {
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }
  mostrarMsg(msg, '');
  mostrarResultado(r.dados);
});

function mostrarResultado(d) {
  areaEmitir.hidden = true;
  areaResultado.hidden = false;
  document.getElementById('r-sub').textContent =
    'O boleto já está à espera de pagamento. Entregue a entidade e a referência a quem tem de pagar.';
  document.getElementById('r-fatura').textContent = d.numero;
  document.getElementById('r-total').textContent = formatarP$(d.valor_total);
  document.getElementById('r-entidade').innerHTML = `<span class="codigo-auth">${esc(d.entidade)}</span>`;
  document.getElementById('r-referencia').innerHTML =
    `<span class="codigo-auth">${esc(d.referencia.slice(0,3))} ${esc(d.referencia.slice(3,6))} ${esc(d.referencia.slice(6,9))}</span>`;

  // o boleto abre numa janela por cima, não noutra aba: quem acabou de
  // emitir quer confirmar o papel e continuar aqui
  document.getElementById('btn-ver-boleto').onclick = () =>
    pcAbrirDocumento({ boleto: d.entidade + '-' + d.referencia });
}

document.getElementById('btn-nova').addEventListener('click', () => {
  areaResultado.hidden = true;
  areaEmitir.hidden = false;
  itens.innerHTML = '';
  novoItem();
  document.getElementById('descricao').value = '';
  recalcular();
});

async function verificarSessao() {
  // repor o estado: esta função corre outra vez depois do login, e sem
  // isto o painel "só quem representa uma empresa" ficava por cima do
  // formulário que acabara de aparecer
  areaSemEmpresa.hidden = true;
  areaEmitir.hidden = true;

  const { data } = await sb.auth.getSession();
  if (!data.session) return;
  pcMostrarApp('Emitir fatura');

  const minha = await minhaEmpresaCedula();
  if (!minha) {
    areaSemEmpresa.hidden = false;
    return;
  }
  areaEmitir.hidden = false;
  itens.innerHTML = '';
  novoItem();
  recalcular();
  await carregarDevedores(minha);
}

pcLigarEntrada(verificarSessao);
verificarSessao();

// ── SAF-T ────────────────────────────────────────────────────────────
//
// O ficheiro nasce no servidor (banco_saft) e não aqui: os dados têm de vir
// da fonte de verdade, e a AT vai recalcular os mesmos totais a partir das
// faturas que ela própria vê. Se o browser montasse o XML, declarar seria
// uma questão de escrever o que apetecesse.

const campoSaft = document.getElementById('saft-competencia');
const msgSaft = document.getElementById('msg-saft');
const resumoSaft = document.getElementById('saft-resumo');
const btnSaft = document.getElementById('btn-saft');

if (campoSaft) {
  const hoje = new Date();
  campoSaft.value = hoje.getFullYear() + '-' + String(hoje.getMonth() + 1).padStart(2, '0');
}

if (btnSaft) {
  btnSaft.addEventListener('click', async () => {
    resumoSaft.hidden = true;
    if (!campoSaft.value) {
      mostrarMsg(msgSaft, 'Escolha o mês a exportar.', 'erro');
      return;
    }

    btnSaft.disabled = true;
    mostrarMsg(msgSaft, 'A montar o ficheiro…');
    const r = await api('banco_saft', { p_competencia: campoSaft.value });
    btnSaft.disabled = false;

    if (!r.ok) {
      mostrarMsg(msgSaft, r.erro, 'erro');
      return;
    }
    const d = r.dados;
    if (d.faturas === 0) {
      mostrarMsg(msgSaft, 'Não emitiu faturas nesse mês — não há nada a declarar.', 'erro');
      return;
    }

    const url = URL.createObjectURL(new Blob([d.xml], { type: 'application/xml' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = d.ficheiro;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);

    resumoSaft.textContent =
      d.faturas + ' fatura(s) · base ' + formatarP$(d.liquido)
      + ' · IVA ' + formatarP$(d.imposto) + ' · total ' + formatarP$(d.bruto);
    resumoSaft.hidden = false;
    mostrarMsg(msgSaft, d.ficheiro + ' descarregado. Entregue-o na AT, em e-Fatura.', 'ok');
  });
}
