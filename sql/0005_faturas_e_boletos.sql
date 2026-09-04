-- Prepacoin — faturas e boletos.
--
-- ## Porquê
--
-- Até aqui, pagar uma taxa a um órgão era: descobrir o IBAN do órgão,
-- fazer uma transferência com o valor certo ao cêntimo, copiar o **UUID**
-- da transação e colá-lo no formulário do órgão. Funciona, mas com ~1000
-- formandos é um gerador de erros — e não ensina nada, porque na vida real
-- ninguém copia identificadores internos entre sites.
--
-- ## O modelo (decidido com o Germano, 2026-09-04)
--
-- Duas coisas ligadas, e serve para **qualquer entidade cobrar de
-- qualquer outra** — órgão a empresa, empresa a empresa:
--
--   FATURA  (`FT-2026-000001`)  diz O QUÊ e QUANTO: linhas, valor, quem
--                               emitiu, quem deve. É o documento.
--   BOLETO  (`BOL-2026-000001`) é a ordem de pagamento gerada a partir
--                               dela: referência, valor, prazo. É o que
--                               se paga no banco.
--
-- Fica no Prepacoin porque é o banco que recebe pagamentos. Os outros
-- apps (Cartório, AT, utilities, e as empresas entre si) emitem por aqui
-- e só perguntam se já foi pago.
--
-- ## A tabela `faturas` que já existia
--
-- Havia uma `faturas` vazia, de uma sessão antiga, pensada só para as
-- utilities (`servico`, `ciclo`, e o devedor em `empresa_cedula`). Não
-- servia: **não tinha quem emite**, logo não conseguia representar "a
-- Padaria faturou ao Restaurante". Como estava vazia, é reconstruída
-- aqui, mantendo `servico` e `ciclo` para o pp-utilities os usar depois.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-04.

-- ---------------------------------------------------------------------
-- 1. Estrutura
-- ---------------------------------------------------------------------
drop table if exists public.fatura_linhas cascade;
drop table if exists public.boletos cascade;
drop table if exists public.faturas cascade;

create table public.faturas (
  id uuid primary key default gen_random_uuid(),
  numero text unique not null,              -- FT-2026-000001
  emitente_cedula text not null,            -- quem cobra (EP-… de empresa ou órgão)
  devedor_cedula text not null,             -- quem deve (EP-… ou PP-…)
  descricao text,
  valor_total bigint not null check (valor_total > 0),   -- cêntimos de P$
  estado text not null default 'emitida',   -- emitida / paga / anulada
  servico text,                             -- para o pp-utilities (agua, energia…)
  ciclo text,                               -- competência, ex.: '2026-08' (texto, R6)
  emitida_em timestamptz not null default now(),
  paga_em timestamptz
);

create table public.fatura_linhas (
  id uuid primary key default gen_random_uuid(),
  fatura_id uuid not null references public.faturas(id) on delete cascade,
  descricao text not null,
  quantidade int not null default 1 check (quantidade > 0),
  valor_unitario bigint not null check (valor_unitario >= 0),
  ordem int not null default 0
);

create table public.boletos (
  id uuid primary key default gen_random_uuid(),
  referencia text unique not null,          -- BOL-2026-000001
  fatura_id uuid not null references public.faturas(id) on delete cascade,
  valor bigint not null check (valor > 0),
  estado text not null default 'por_pagar', -- por_pagar / em_pagamento / pago / expirado
  prazo timestamptz,
  transacao_id uuid,                        -- a transferência que o pagou
  emitido_em timestamptz not null default now(),
  pago_em timestamptz
);

create index if not exists idx_faturas_devedor on public.faturas(devedor_cedula, estado);
create index if not exists idx_faturas_emitente on public.faturas(emitente_cedula, estado);
create index if not exists idx_boletos_fatura on public.boletos(fatura_id);

alter table public.faturas enable row level security;
alter table public.fatura_linhas enable row level security;
alter table public.boletos enable row level security;

-- Vê quem emitiu e quem deve. O professor vê tudo.
create policy "faturas minhas" on public.faturas for select
  using (
    public.fn_cedula_minha(emitente_cedula)
    or public.fn_cedula_minha(devedor_cedula)
    or public.fn_e_professor()
  );

create policy "linhas das faturas que vejo" on public.fatura_linhas for select
  using (exists (
    select 1 from public.faturas f
    where f.id = fatura_id
      and (public.fn_cedula_minha(f.emitente_cedula)
        or public.fn_cedula_minha(f.devedor_cedula)
        or public.fn_e_professor())
  ));

create policy "boletos das faturas que vejo" on public.boletos for select
  using (exists (
    select 1 from public.faturas f
    where f.id = fatura_id
      and (public.fn_cedula_minha(f.emitente_cedula)
        or public.fn_cedula_minha(f.devedor_cedula)
        or public.fn_e_professor())
  ));

-- Escrita só por RPC (as RPCs são SECURITY DEFINER e passam por cima).

-- ---------------------------------------------------------------------
-- 2. Numeração
-- ---------------------------------------------------------------------
create or replace function public.fn_proximo_numero_doc(p_tipo text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ano int := extract(year from now());
  v_seq int;
  v_pref text := case p_tipo when 'fatura' then 'FT' when 'boleto' then 'BOL' else 'DOC' end;
begin
  insert into public.contador_protocolo(orgao, ano, ultimo) values (p_tipo, v_ano, 1)
  on conflict (orgao, ano) do update set ultimo = contador_protocolo.ultimo + 1
  returning ultimo into v_seq;
  return v_pref || '-' || v_ano || '-' || lpad(v_seq::text, 6, '0');
end;
$$;
revoke execute on function public.fn_proximo_numero_doc(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Emissão interna (sem checar quem chama)
-- ---------------------------------------------------------------------
-- É esta que os órgãos usam: eles não têm funcionários, logo não há
-- sessão de "alguém do Cartório" para validar. Revogada de PUBLIC — só
-- corre de dentro de outra SECURITY DEFINER.
create or replace function public.banco_emitir_fatura_interna(
  p_emitente text,
  p_devedor text,
  p_descricao text,
  p_linhas jsonb,           -- [{descricao, quantidade, valor_unitario}, …]
  p_dias int default 30,
  p_servico text default null,
  p_ciclo text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fatura uuid := gen_random_uuid();
  v_numero text;
  v_ref text;
  v_total bigint := 0;
  v_linha jsonb;
  v_i int := 0;
  v_prazo timestamptz;
begin
  if p_emitente is null or p_devedor is null then
    return jsonb_build_object('ok', false, 'erro', 'Emitente e devedor são obrigatórios.');
  end if;
  if p_emitente = p_devedor then
    return jsonb_build_object('ok', false, 'erro', 'Uma entidade não pode faturar a si própria.');
  end if;
  if not exists (select 1 from public.contas where cedula = p_devedor) then
    return jsonb_build_object('ok', false, 'erro', 'O devedor não tem conta no Prepacoin.');
  end if;
  if not exists (select 1 from public.contas where cedula = p_emitente) then
    return jsonb_build_object('ok', false, 'erro', 'O emitente não tem conta no Prepacoin.');
  end if;
  if p_linhas is null or jsonb_array_length(p_linhas) = 0 then
    return jsonb_build_object('ok', false, 'erro', 'A fatura precisa de pelo menos uma linha.');
  end if;

  for v_linha in select * from jsonb_array_elements(p_linhas) loop
    if coalesce(btrim(v_linha->>'descricao'), '') = '' then
      return jsonb_build_object('ok', false, 'erro', 'Toda a linha precisa de descrição.');
    end if;
    if coalesce((v_linha->>'valor_unitario')::bigint, 0) < 0
       or coalesce((v_linha->>'quantidade')::int, 1) <= 0 then
      return jsonb_build_object('ok', false, 'erro', 'Quantidade ou valor inválido numa linha.');
    end if;
    v_total := v_total + coalesce((v_linha->>'valor_unitario')::bigint, 0)
                       * coalesce((v_linha->>'quantidade')::int, 1);
  end loop;

  if v_total <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'O total da fatura tem de ser positivo.');
  end if;

  v_numero := public.fn_proximo_numero_doc('fatura');
  v_ref := public.fn_proximo_numero_doc('boleto');
  v_prazo := now() + (least(greatest(coalesce(p_dias, 30), 1), 365) || ' days')::interval;

  insert into public.faturas(id, numero, emitente_cedula, devedor_cedula,
    descricao, valor_total, servico, ciclo)
  values (v_fatura, v_numero, p_emitente, p_devedor, p_descricao, v_total, p_servico, p_ciclo);

  for v_linha in select * from jsonb_array_elements(p_linhas) loop
    v_i := v_i + 1;
    insert into public.fatura_linhas(fatura_id, descricao, quantidade, valor_unitario, ordem)
    values (v_fatura, btrim(v_linha->>'descricao'),
            coalesce((v_linha->>'quantidade')::int, 1),
            coalesce((v_linha->>'valor_unitario')::bigint, 0), v_i);
  end loop;

  insert into public.boletos(referencia, fatura_id, valor, prazo)
  values (v_ref, v_fatura, v_total, v_prazo);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'fatura_id', v_fatura, 'numero', v_numero, 'referencia', v_ref,
    'valor_total', v_total, 'prazo', v_prazo));
end;
$$;
revoke execute on function public.banco_emitir_fatura_interna(text, text, text, jsonb, int, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Emissão pública — em nome da minha empresa
-- ---------------------------------------------------------------------
create or replace function public.banco_emitir_fatura(
  p_devedor text,
  p_descricao text,
  p_linhas jsonb,
  p_dias int default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_emitente text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  -- fatura-se sempre em nome da empresa; a identidade vem da sessão
  v_emitente := public.fn_minha_empresa_cedula();
  if v_emitente is null then
    return jsonb_build_object('ok', false, 'erro',
      'Só quem está vinculado a uma empresa pode emitir faturas.');
  end if;
  return public.banco_emitir_fatura_interna(
    v_emitente, btrim(p_devedor), p_descricao, p_linhas, p_dias, null, null);
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao emitir fatura: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Pagar um boleto
-- ---------------------------------------------------------------------
-- Reaproveita `banco_transferir`, e por isso herda tudo o que ele já
-- garante: dono da conta, saldo disponível a descontar pendentes, e o
-- limite de aprovação. Se a fatura passar o limite da conta, a
-- transferência fica pendente e o boleto fica `em_pagamento` até um
-- gerente aprovar — que é o comportamento certo para uma despesa grande.
create or replace function public.banco_pagar_boleto(p_referencia text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  b record;
  f record;
  v_origem text;
  v_destino text;
  v_res jsonb;
  v_estado text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  select * into b from public.boletos
    where upper(referencia) = upper(btrim(p_referencia)) for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Boleto não encontrado.');
  end if;
  if b.estado = 'pago' then
    return jsonb_build_object('ok', false, 'erro', 'Este boleto já foi pago.');
  end if;
  if b.estado = 'em_pagamento' then
    return jsonb_build_object('ok', false, 'erro',
      'Este boleto já tem um pagamento à espera de aprovação.');
  end if;

  select * into f from public.faturas where id = b.fatura_id;
  if f.estado = 'anulada' then
    return jsonb_build_object('ok', false, 'erro', 'A fatura foi anulada.');
  end if;

  -- só quem controla a conta do devedor é que paga
  if not public.fn_cedula_minha(f.devedor_cedula) then
    return jsonb_build_object('ok', false, 'erro', 'Este boleto não é da sua entidade.');
  end if;

  select iban into v_origem from public.contas where cedula = f.devedor_cedula;
  select iban into v_destino from public.contas where cedula = f.emitente_cedula;
  if v_origem is null or v_destino is null then
    return jsonb_build_object('ok', false, 'erro', 'Falta conta do devedor ou do emitente.');
  end if;

  v_res := public.banco_transferir(v_origem, v_destino, b.valor,
    coalesce(f.servico, 'fatura'), 'Boleto ' || b.referencia || ' · fatura ' || f.numero);

  if not (v_res->>'ok')::boolean then
    return v_res;   -- saldo insuficiente, conta bloqueada, etc.
  end if;

  v_estado := v_res->'dados'->>'estado';

  if v_estado = 'concluida' then
    update public.boletos set estado = 'pago', pago_em = now(),
      transacao_id = (v_res->'dados'->>'id')::uuid where id = b.id;
    update public.faturas set estado = 'paga', paga_em = now() where id = f.id;
  else
    -- acima do limite: espera aprovação de um gerente
    update public.boletos set estado = 'em_pagamento',
      transacao_id = (v_res->'dados'->>'id')::uuid where id = b.id;
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'referencia', b.referencia, 'fatura', f.numero, 'valor', b.valor,
    'estado', case when v_estado = 'concluida' then 'pago' else 'em_pagamento' end,
    'codigo', v_res->'dados'->>'codigo',
    'aviso', case when v_estado <> 'concluida'
                  then 'Acima do limite: aguarda aprovação de um gerente.' end));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao pagar boleto: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Fechar o boleto quando a transferência pendente é aprovada
-- ---------------------------------------------------------------------
-- Sem isto, um boleto pago acima do limite ficava eternamente
-- `em_pagamento` mesmo depois de o gerente aprovar.
create or replace function public.banco_decidir_pendente(
  p_transacao_id uuid,
  p_aprovar boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_tx record; v_conta record; v_pessoa record;
  v_codigo text; v_pendentes_antes bigint;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  select p.cedula, p.papel into v_pessoa from public.pessoas p where p.id = auth.uid();
  if v_pessoa.cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select * into v_tx from public.transacoes where id = p_transacao_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Transação não encontrada.');
  end if;
  if v_tx.estado <> 'pendente' then
    return jsonb_build_object('ok', false, 'erro', 'Esta transação já foi decidida.');
  end if;

  select * into v_conta from public.contas where iban = v_tx.origem_iban for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Conta de origem inexistente.');
  end if;

  if v_conta.cedula is distinct from public.fn_minha_empresa_cedula()
     or coalesce(v_pessoa.papel, '') <> 'gerente' then
    return jsonb_build_object('ok', false, 'erro',
      'Só um gerente da empresa dona da conta pode decidir esta transferência.');
  end if;

  if not p_aprovar then
    update public.transacoes set estado = 'rejeitada', decidida_por = v_pessoa.cedula
      where id = p_transacao_id;
    -- o boleto volta a estar por pagar
    update public.boletos set estado = 'por_pagar', transacao_id = null
      where transacao_id = p_transacao_id and estado = 'em_pagamento';
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('estado', 'rejeitada'));
  end if;

  select coalesce(sum(valor), 0) into v_pendentes_antes
    from public.transacoes
    where origem_iban = v_tx.origem_iban and estado = 'pendente' and id <> p_transacao_id;

  if v_conta.saldo - v_pendentes_antes < v_tx.valor then
    return jsonb_build_object('ok', false, 'erro',
      'Saldo insuficiente agora para aprovar esta transferência.');
  end if;

  update public.contas set saldo = saldo - v_tx.valor where iban = v_tx.origem_iban;
  update public.contas set saldo = saldo + v_tx.valor where iban = v_tx.destino_iban;

  v_codigo := upper(left(encode(digest(v_tx.id::text || now()::text, 'sha256'), 'hex'), 12));
  update public.transacoes
    set estado = 'concluida', codigo_auth = v_codigo, decidida_por = v_pessoa.cedula
    where id = p_transacao_id;

  -- e agora fecha o boleto e a fatura, se este pagamento era de um
  update public.boletos set estado = 'pago', pago_em = now()
    where transacao_id = p_transacao_id and estado = 'em_pagamento';
  update public.faturas set estado = 'paga', paga_em = now()
    where id in (select fatura_id from public.boletos where transacao_id = p_transacao_id)
      and estado <> 'paga';

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'estado', 'concluida', 'codigo', v_codigo));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao decidir: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Consultas
-- ---------------------------------------------------------------------
-- O que a minha entidade tem por pagar (o ecrã "Boletos por pagar").
create or replace function public.banco_boletos_por_pagar(p_cedula text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_cedula text; v_linhas jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  v_cedula := coalesce(p_cedula, public.fn_minha_empresa_cedula(), public.fn_minha_cedula());
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if not (public.fn_e_professor() or public.fn_cedula_minha(v_cedula)) then
    return jsonb_build_object('ok', false, 'erro', 'Sem acesso.');
  end if;

  select coalesce(jsonb_agg(l order by l->>'prazo'), '[]'::jsonb) into v_linhas
  from (
    select jsonb_build_object(
      'referencia', b.referencia, 'fatura', f.numero, 'valor', b.valor,
      'estado', b.estado, 'prazo', b.prazo, 'atrasado', b.prazo < now(),
      'descricao', f.descricao,
      'emitente', f.emitente_cedula,
      'emitente_nome', coalesce(e.nome, f.emitente_cedula)
    ) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    left join public.empresas e on e.cedula = f.emitente_cedula
    where f.devedor_cedula = v_cedula
      and b.estado in ('por_pagar', 'em_pagamento')
      and f.estado <> 'anulada'
  ) s;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula, 'boletos', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao listar: ' || sqlerrm);
end;
$$;

-- Consulta pública de uma fatura pelo número — a prova para quem cobrou.
create or replace function public.banco_verificar_fatura(p_numero text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare f record; b record; v_linhas jsonb;
begin
  if p_numero is null or btrim(p_numero) = '' then
    return jsonb_build_object('ok', false, 'erro', 'Número obrigatório.');
  end if;
  select * into f from public.faturas where upper(numero) = upper(btrim(p_numero));
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Fatura não encontrada.');
  end if;
  select * into b from public.boletos where fatura_id = f.id order by emitido_em limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'descricao', descricao, 'quantidade', quantidade,
    'valor_unitario', valor_unitario,
    'total', quantidade * valor_unitario) order by ordem), '[]'::jsonb)
  into v_linhas from public.fatura_linhas where fatura_id = f.id;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'numero', f.numero,
    'emitente', (select coalesce(nome, f.emitente_cedula) from public.empresas where cedula = f.emitente_cedula),
    'emitente_cedula', f.emitente_cedula,
    'devedor_cedula', f.devedor_cedula,
    'descricao', f.descricao,
    'valor_total', f.valor_total,
    'estado', f.estado,
    'paga', f.estado = 'paga',
    'emitida_em', f.emitida_em,
    'paga_em', f.paga_em,
    'referencia_boleto', b.referencia,
    'prazo', b.prazo,
    'linhas', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao verificar: ' || sqlerrm);
end;
$$;
