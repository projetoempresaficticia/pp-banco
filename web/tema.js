// Prepacoin — alternador de tema.
//
// Três estados, não dois: "sistema" (por omissão), "claro" e "escuro".
// Só a escolha explícita escreve `data-tema` na raiz; sem escolha, quem
// manda é o `prefers-color-scheme` do sistema. É por isso que o CSS
// define o claro em `:root` e o escuro em dois sítios: no media query
// (guardado com `:not([data-tema="claro"])`) e em `[data-tema="escuro"]`.
//
// A escolha vive no localStorage, que é por browser. Não é definição de
// conta: quem entra noutro computador volta ao tema do sistema, e está
// bem assim.

(function () {
  const CHAVE = 'pc-tema';

  function lerEscolha() {
    try {
      const v = localStorage.getItem(CHAVE);
      return v === 'claro' || v === 'escuro' ? v : null;
    } catch (e) {
      // janela anónima ou site data bloqueado: seguimos com o sistema
      return null;
    }
  }

  function aplicar(escolha) {
    if (escolha) document.documentElement.setAttribute('data-tema', escolha);
    else document.documentElement.removeAttribute('data-tema');
  }

  function escuroAgora() {
    const escolha = lerEscolha();
    if (escolha) return escolha === 'escuro';
    return window.matchMedia('(prefers-color-scheme: dark)').matches;
  }

  // aplicar antes de pintar, para não haver um flash do tema errado
  aplicar(lerEscolha());

  function ligarBotao() {
    const btn = document.getElementById('btn-tema');
    if (!btn) return;

    function rotular() {
      const escuro = escuroAgora();
      btn.setAttribute('aria-pressed', String(escuro));
      btn.title = escuro ? 'Mudar para tema claro' : 'Mudar para tema escuro';
    }

    btn.addEventListener('click', () => {
      const novo = escuroAgora() ? 'claro' : 'escuro';
      try { localStorage.setItem(CHAVE, novo); } catch (e) { /* sem persistência */ }
      aplicar(novo);
      rotular();
    });

    rotular();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ligarBotao);
  } else {
    ligarBotao();
  }
})();
