// Prepacoin — as peças que as sete páginas repetem.
//
// O rail, a barra de topo e o ecrã de entrada eram os mesmos em todas as
// páginas, copiados à mão. Copiado à mão significa que uma correção só
// chega a algumas: foi assim que a navegação ficou diferente em cada
// ecrã. Aqui montam-se uma vez.

const PC_PAGINAS = [
  { href: 'index.html',      icone: 'i-conta',      nome: 'A minha conta' },
  { href: 'transferir.html', icone: 'i-transferir', nome: 'Transferir' },
  { href: 'boletos.html',    icone: 'i-recibo',     nome: 'Boletos' },
  { href: 'emitir.html',     icone: 'i-cartao',     nome: 'Emitir fatura' },
  { href: 'aprovacoes.html', icone: 'i-aprovado',   nome: 'Aprovações' },
];

function pcEscapar(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Qual página está aberta agora. Serve para o aria-current, que é o que
// diz a um leitor de ecrã onde a pessoa está.
function pcPaginaAtual() {
  const f = window.location.pathname.split('/').pop();
  return f === '' ? 'index.html' : f;
}

function pcMontarRail(alvo) {
  const atual = pcPaginaAtual();
  alvo.className = 'rail';
  alvo.setAttribute('aria-label', 'Navegação principal');
  alvo.innerHTML =
    '<div class="rail-marca" aria-hidden="true">P$</div>' +
    PC_PAGINAS.map((p) => `
      <a href="${p.href}" title="${pcEscapar(p.nome)}"
         ${p.href === atual ? 'aria-current="page"' : ''}>
        <span class="icone icone-24 ${p.icone}"></span>
        <span class="so-leitores">${pcEscapar(p.nome)}</span>
      </a>`).join('') + `
      <a href="biblioteca.html" class="empurra" title="Biblioteca"
         ${atual === 'biblioteca.html' ? 'aria-current="page"' : ''}>
        <span class="icone icone-24 i-categorias"></span>
        <span class="so-leitores">Biblioteca</span>
      </a>`;
}

function pcMontarBarra(alvo, titulo) {
  alvo.className = 'barra-topo';
  alvo.innerHTML = `
    <span class="marca">${pcEscapar(titulo || 'Prepacoin')}</span>
    <div class="fila">
      <span class="suave" id="pc-quem" style="font-size:13px"></span>
      <button type="button" class="botao-icone" id="btn-tema" title="Alternar tema">
        <span class="icone i-lua"></span><span class="so-leitores">Alternar tema</span>
      </button>
      <button type="button" class="secundario" id="btn-sair">Sair</button>
    </div>`;
}

// Escreve quem está com a sessão aberta. Sem isto, num laboratório onde
// vários formandos usam a mesma máquina, ninguém sabe em nome de quem
// está a mexer no dinheiro.
//
// Usa `getSession()` e não `getUser()` de propósito: o `getUser()` vai
// validar o token ao servidor, e duas chamadas em paralelo logo a seguir
// ao login entram em contenção. Uma delas devolvia `user: null` e este
// campo ficava em branco sem dar erro nenhum. O `getSession()` lê o que
// já está em memória e não tem esse problema.
async function pcMostrarQuem() {
  const el = document.getElementById('pc-quem');
  if (!el) return;
  const { data } = await sb.auth.getSession();
  const uid = data.session && data.session.user && data.session.user.id;
  if (!uid) return;

  const { data: p, error } = await sb.from('pessoas')
    .select('nome, cedula').eq('id', uid).single();
  if (error || !p) {
    // melhor o email do que um espaço em branco
    el.textContent = data.session.user.email || '';
    return;
  }
  el.textContent = `${p.nome} · ${p.cedula}`;
}

// Liga o botão Sair onde quer que ele esteja.
function pcLigarSair(antes) {
  const btn = document.getElementById('btn-sair');
  if (!btn) return;
  btn.addEventListener('click', async () => {
    if (typeof antes === 'function') antes();
    await sb.auth.signOut();
    window.location.reload();
  });
}

// Tudo o que as sete páginas fazem igual quando há sessão: esconder a
// entrada, mostrar a aplicação, montar a navegação e dizer quem entrou.
// Cada página só chama isto e trata do que é seu.
function pcMostrarApp(titulo, antesDeSair) {
  const entrada = document.getElementById('area-login');
  const app = document.getElementById('app');
  if (entrada) entrada.hidden = true;
  if (app) app.hidden = false;

  const rail = document.getElementById('rail');
  const barra = document.getElementById('barra');
  if (rail) pcMontarRail(rail);
  if (barra) pcMontarBarra(barra, titulo);

  pcLigarSair(antesDeSair);
  pcMostrarQuem();
}

// O formulário de entrada é o mesmo nas sete páginas: mesmos ids, mesma
// mensagem de erro, mesma coisa a seguir.
function pcLigarEntrada(aoEntrar) {
  const form = document.getElementById('form-login');
  if (!form) return;
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const msg = document.getElementById('msg-login');
    mostrarMsg(msg, 'A entrar…', null);
    const { error } = await sb.auth.signInWithPassword({
      email: document.getElementById('email').value,
      password: document.getElementById('senha').value,
    });
    if (error) { mostrarMsg(msg, 'Email ou senha incorretos.', 'erro'); return; }
    mostrarMsg(msg, '', null);
    await aoEntrar();
  });
}
