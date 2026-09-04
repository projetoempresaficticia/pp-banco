// Prepacoin — emitir fatura com itens, e o boleto que sai dela.
//
// O total é somado aqui só para o utilizador ver enquanto escreve; quem
// manda é o servidor, que volta a somar a partir das linhas. Se os dois
// discordarem, é o do servidor que vale.

const areaLogin = document.getElementById('area-login');
const areaEmitir = document.getElementById('area-emitir');
const areaResultado = document.getElementById('area-resultado');
const areaSemEmpresa = document.getElementById('area-sem-empresa');
const navLogado = document.getElementById('nav-logado');
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
  document.getElementById('r-boleto-link').href =
    'documento.html?boleto=' + encodeURIComponent(d.entidade + '-' + d.referencia);
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
  areaLogin.hidden = true;
  navLogado.hidden = false;

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
