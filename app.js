// Prepacoin — dashboard: saldo, IBAN e movimentos, com saldo em tempo real.

const areaLogin = document.getElementById('area-login');
const areaConta = document.getElementById('area-conta');
const areaSemConta = document.getElementById('area-sem-conta');
const navLogado = document.getElementById('nav-logado');
const formLogin = document.getElementById('form-login');
const msgLogin = document.getElementById('msg-login');
const seletorConta = document.getElementById('seletor-conta');

let cedulasDisponiveis = []; // a própria pessoa e (se houver) a empresa
let cedulaAtual = null;
let canalRealtime = null;

// Quais contas esta pessoa pode ver: a dela e a da empresa a que está
// vinculada. A RLS já filtra, mas precisamos das cédulas para o seletor.
async function carregarCedulas() {
  const { data: user } = await sb.auth.getUser();
  if (!user.user) return [];

  const { data: pessoa } = await sb
    .from('pessoas')
    .select('cedula, nome, empresa_id')
    .eq('id', user.user.id)
    .single();
  if (!pessoa) return [];

  const lista = [{ cedula: pessoa.cedula, rotulo: `${pessoa.nome} (pessoal)` }];

  if (pessoa.empresa_id) {
    const { data: empresa } = await sb
      .from('empresas')
      .select('cedula, nome')
      .eq('id', pessoa.empresa_id)
      .single();
    if (empresa) lista.push({ cedula: empresa.cedula, rotulo: `${empresa.nome} (empresa)` });
  }
  return lista;
}

function desenharSeletor() {
  if (cedulasDisponiveis.length < 2) {
    seletorConta.hidden = true;
    return;
  }
  seletorConta.hidden = false;
  seletorConta.innerHTML = cedulasDisponiveis
    .map((c) => `<option value="${c.cedula}" ${c.cedula === cedulaAtual ? 'selected' : ''}>${c.rotulo}</option>`)
    .join('');
}

async function carregarConta() {
  const msg = document.getElementById('msg-conta');
  mostrarMsg(msg, '', null);

  const r = await api('banco_saldo', { p_cedula: cedulaAtual });
  if (!r.ok) {
    // sem conta aberta ainda é o caso normal de quem acabou de entrar
    if (r.erro && r.erro.includes('ainda não tem conta')) {
      areaConta.hidden = true;
      areaSemConta.hidden = false;
      return;
    }
    areaConta.hidden = true;
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }

  areaSemConta.hidden = true;
  areaConta.hidden = false;

  const d = r.dados;
  const disponivel = Number(d.saldo) - Number(d.pendente_saida || 0);
  document.getElementById('c-saldo').textContent = formatarP$(disponivel);
  document.getElementById('c-iban').textContent = formatarIban(d.iban);

  const preso = document.getElementById('c-preso');
  preso.textContent = Number(d.pendente_saida) > 0
    ? `${formatarP$(d.pendente_saida)} à espera de aprovação · saldo total ${formatarP$(d.saldo)}`
    : '';

  document.getElementById('titulo-conta').textContent =
    cedulaAtual && cedulaAtual.startsWith('EP-') ? 'Conta da empresa' : 'A minha conta';

  await carregarMovimentos();
  ligarRealtime(d.iban);
}

async function carregarMovimentos() {
  const alvo = document.getElementById('lista-movimentos');
  const r = await api('banco_extrato', { p_cedula: cedulaAtual, p_limite: 30 });

  if (!r.ok) {
    alvo.innerHTML = `<p class="vazio">Erro ao carregar: ${r.erro}</p>`;
    return;
  }
  const movimentos = r.dados.movimentos || [];
  if (!movimentos.length) {
    alvo.innerHTML = '<p class="vazio">Sem movimentos ainda.</p>';
    return;
  }

  alvo.innerHTML = movimentos
    .map((m) => {
      const entrada = m.sentido === 'entrada';
      const sinal = entrada ? '+' : '−';
      const classeValor = m.estado === 'rejeitada'
        ? 'anulado'
        : entrada ? 'entrada' : 'saida';
      const contraparte = m.contraparte === 'emissão'
        ? 'emissão do banco'
        : formatarIban(m.contraparte);
      return `
        <div class="movimento">
          <div>
            <div class="mov-categoria">${m.categoria || 'transferência'} ${badgeEstado(m.estado)}</div>
            <div class="mov-detalhe">
              ${m.descricao ? m.descricao + ' · ' : ''}${entrada ? 'de' : 'para'} ${contraparte}
              · ${formatarData(m.criada_em)}
              ${m.codigo_auth ? `· <span class="codigo-auth">${m.codigo_auth}</span>` : ''}
            </div>
          </div>
          <div class="mov-valor ${classeValor}">${sinal} ${formatarP$(m.valor)}</div>
        </div>`;
    })
    .join('');
}

// Saldo em tempo real: a skill pede Realtime em vez de recarregar a página.
function ligarRealtime(iban) {
  if (canalRealtime) {
    sb.removeChannel(canalRealtime);
    canalRealtime = null;
  }
  canalRealtime = sb
    .channel('prepacoin-' + iban)
    .on('postgres_changes',
      { event: '*', schema: 'public', table: 'transacoes' },
      () => carregarConta())
    .subscribe();
}

seletorConta.addEventListener('change', () => {
  cedulaAtual = seletorConta.value;
  carregarConta();
});

document.getElementById('btn-abrir-conta').addEventListener('click', async (ev) => {
  const msg = document.getElementById('msg-abrir');
  ev.target.disabled = true;
  mostrarMsg(msg, 'A abrir a conta…', null);

  const r = await api('banco_abrir_conta', { p_cedula: cedulaAtual, p_limite: 100000 });
  ev.target.disabled = false;

  if (!r.ok) {
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }
  mostrarMsg(msg, 'Conta aberta! IBAN ' + formatarIban(r.dados.iban), 'sucesso');
  carregarConta();
});

async function verificarSessao() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return;

  areaLogin.hidden = true;
  navLogado.hidden = false;

  cedulasDisponiveis = await carregarCedulas();
  if (!cedulasDisponiveis.length) {
    document.getElementById('msg-conta').textContent =
      'Esta conta de acesso ainda não tem ficha na Carteirinha (ClassCard).';
    return;
  }
  cedulaAtual = cedulasDisponiveis[0].cedula;
  desenharSeletor();
  carregarConta();
}

formLogin.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  mostrarMsg(msgLogin, '', null);
  const email = document.getElementById('email').value;
  const senha = document.getElementById('senha').value;
  const { error } = await sb.auth.signInWithPassword({ email, password: senha });
  if (error) {
    mostrarMsg(msgLogin, 'Login inválido.', 'erro');
    return;
  }
  await verificarSessao();
});

document.getElementById('btn-sair').addEventListener('click', async () => {
  if (canalRealtime) sb.removeChannel(canalRealtime);
  await sb.auth.signOut();
  window.location.reload();
});

verificarSessao();
