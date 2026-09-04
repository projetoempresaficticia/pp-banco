// Prepacoin — utilitários partilhados pelas páginas do banco.
// O cliente Supabase (`sb`) e o `api()` vêm do comum.js da pp-base.

// Dinheiro é sempre bigint em cêntimos de P$ (R7 da pp-base). Formatar
// só no ecrã — nunca guardar nem calcular com o valor formatado.
function formatarP$(centimos) {
  const valor = Number(centimos || 0) / 100;
  return 'P$ ' + valor.toLocaleString('pt-PT', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

// "12,34" ou "12.34" → 1234 cêntimos. Devolve null se não for válido.
function paraCentimos(texto) {
  const limpo = String(texto || '').trim().replace(/\s/g, '').replace(',', '.');
  if (!/^\d+(\.\d{1,2})?$/.test(limpo)) return null;
  return Math.round(parseFloat(limpo) * 100);
}

function formatarDataHora(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('pt-PT', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

function formatarIban(iban) {
  if (!iban) return '—';
  return iban.replace(/(.{4})/g, '$1 ').trim();
}

function formatarData(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('pt-PT', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

// Cada estado leva ícone E palavra, nunca só a cor: quem não distingue
// verde de vermelho tem de continuar a perceber o que se passou.
const PC_ESTADOS = {
  concluida:    { rotulo: 'Concluída',   icone: 'i-aprovado' },
  pendente:     { rotulo: 'Pendente',    icone: 'i-info' },
  rejeitada:    { rotulo: 'Rejeitada',   icone: 'i-info' },
  pago:         { rotulo: 'Pago',        icone: 'i-aprovado' },
  paga:         { rotulo: 'Paga',        icone: 'i-aprovado' },
  por_pagar:    { rotulo: 'Por pagar',   icone: 'i-info' },
  em_pagamento: { rotulo: 'À espera de aprovação', icone: 'i-info' },
  cancelado:    { rotulo: 'Cancelado',   icone: 'i-info' },
  anulada:      { rotulo: 'Anulada',     icone: 'i-info' },
};

function badgeEstado(estado) {
  const e = PC_ESTADOS[estado] || { rotulo: estado, icone: 'i-info' };
  return `<span class="badge badge-${estado}">`
       + `<span class="icone ${e.icone}"></span>${e.rotulo}</span>`;
}

function mostrarMsg(el, texto, tipo) {
  el.textContent = texto;
  el.className = 'msg' + (tipo ? ' ' + tipo : '');
}
