-- Prepacoin — boletos com referência a sério, trazida do projeto original.
--
-- ## De onde vem isto
--
-- O Prepacoin nasceu em Google Apps Script (pasta `prepacoin/` no repo de
-- documentação) e já tinha um sistema de boletos mais completo do que o
-- que se construiu aqui de raiz. Ao comparar, o original ganhava em:
--
--   · **Entidade (5 dígitos) + Referência (9 dígitos)** no formato dos
--     pagamentos de serviços em Portugal, em vez do nosso
--     `BOL-2026-000001` sequencial;
--   · o último dígito da referência é um **dígito de controlo (Luhn)**,
--     que apanha erros de digitação antes sequer de ir à base;
--   · **consultar antes de pagar** — ver emitente, valor e descrição, e
--     só depois confirmar;
--   · **cancelar** um boleto em aberto (só o emitente);
--   · lista separada entre o que a empresa **tem a pagar** e o que
--     **emitiu**.
--
-- O que o nosso já tinha de melhor fica: faturas com linhas discriminadas
-- (o original só tinha uma descrição), e o limite de aprovação herdado da
-- transferência.
--
-- ## Porque a referência importa pedagogicamente
--
-- É assim que se paga água, luz ou impostos em Portugal: escreve-se a
-- entidade e a referência no homebanking. Um número sequencial não ensina
-- nada disso, e ainda deixa passar erros de digitação sem aviso.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-04.

-- ---------------------------------------------------------------------
-- 1. Colunas novas
-- ---------------------------------------------------------------------
-- A coluna `referencia` já existia e guarda o número do documento
-- (`BOL-2026-000001`). Os 9 dígitos que se escrevem no homebanking são
-- outra coisa, e vivem em `referencia_mb` — os dois identificadores
-- coexistem no mesmo boleto e não se misturam.
alter table public.boletos
  add column if not exists entidade text,
  add column if not exists referencia_mb text;

create unique index if not exists idx_boleto_ent_ref
  on public.boletos(entidade, referencia_mb);

-- ---------------------------------------------------------------------
-- 2. Dígito de controlo (Luhn) — o que apanha erros de digitação
-- ---------------------------------------------------------------------
create or replace function public.fn_digito_controlo(p_digitos text)
returns text
language plpgsql
immutable
as $$
declare
  v_soma int := 0;
  v_alt boolean := false;
  v_d int;
  i int;
begin
  for i in reverse length(p_digitos)..1 loop
    v_d := substr(p_digitos, i, 1)::int;
    if v_alt then
      v_d := v_d * 2;
      if v_d > 9 then v_d := v_d - 9; end if;
    end if;
    v_soma := v_soma + v_d;
    v_alt := not v_alt;
  end loop;
  return ((10 - (v_soma % 10)) % 10)::text;
end;
$$;

-- A entidade identifica quem cobra, derivada da cédula: EP-2026-00009 → 20009.
create or replace function public.fn_entidade_de(p_cedula text)
returns text
language sql
immutable
as $$
  select lpad((20000 + (coalesce(nullif(regexp_replace(p_cedula, '\D', '', 'g'), ''), '0')::bigint % 10000))::text, 5, '0');
$$;

create or replace function public.fn_gerar_referencia()
returns text
language plpgsql
set search_path = public
as $$
declare v_base text; v_ref text; v_i int := 0;
begin
  loop
    v_base := lpad(floor(random() * 100000000)::bigint::text, 8, '0');
    v_ref := v_base || public.fn_digito_controlo(v_base);
    exit when not exists (select 1 from public.boletos where referencia_mb = v_ref);
    v_i := v_i + 1;
    if v_i >= 20 then raise exception 'Não foi possível gerar referência única.'; end if;
  end loop;
  return v_ref;
end;
$$;

revoke execute on function public.fn_gerar_referencia() from public, anon, authenticated;
revoke execute on function public.fn_entidade_de(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. A emissão passa a gerar entidade + referência
-- ---------------------------------------------------------------------
create or replace function public.banco_emitir_fatura_interna(
  p_emitente text, p_devedor text, p_descricao text, p_linhas jsonb,
  p_dias int default 30, p_servico text default null, p_ciclo text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fatura uuid := gen_random_uuid(); v_numero text; v_ref text; v_ent text;
  v_total bigint := 0; v_linha jsonb; v_i int := 0; v_prazo timestamptz;
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
  v_ref := public.fn_gerar_referencia();
  v_ent := public.fn_entidade_de(p_emitente);
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

  insert into public.boletos(referencia, entidade, fatura_id, valor, prazo)
  values (public.fn_proximo_numero_doc('boleto'), v_ent, v_fatura, v_total, v_prazo);

  update public.boletos set referencia_mb = v_ref
    where fatura_id = v_fatura;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'fatura_id', v_fatura, 'numero', v_numero,
    'entidade', v_ent, 'referencia', v_ref,
    'linha', v_ent || ' ' || substr(v_ref,1,3) || ' ' || substr(v_ref,4,3) || ' ' || substr(v_ref,7,3),
    'valor_total', v_total, 'prazo', v_prazo));
end;
$$;
revoke execute on function public.banco_emitir_fatura_interna(text, text, text, jsonb, int, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Consultar antes de pagar
-- ---------------------------------------------------------------------
-- Valida o dígito de controlo ANTES de ir à base: um engano na digitação
-- é apanhado logo, com uma mensagem que diz o que se passa.
create or replace function public.banco_consultar_boleto(
  p_entidade text, p_referencia text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ent text := regexp_replace(coalesce(p_entidade, ''), '\D', '', 'g');
  v_ref text := regexp_replace(coalesce(p_referencia, ''), '\D', '', 'g');
  b record; f record; v_linhas jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if length(v_ent) <> 5 then
    return jsonb_build_object('ok', false, 'erro', 'A entidade tem de ter 5 dígitos.');
  end if;
  if length(v_ref) <> 9 then
    return jsonb_build_object('ok', false, 'erro', 'A referência tem de ter 9 dígitos.');
  end if;
  if public.fn_digito_controlo(substr(v_ref, 1, 8)) <> substr(v_ref, 9, 1) then
    return jsonb_build_object('ok', false, 'erro', 'Referência inválida — confira os dígitos.');
  end if;

  select * into b from public.boletos where entidade = v_ent and referencia_mb = v_ref;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Não existe nenhum boleto com esta referência.');
  end if;
  select * into f from public.faturas where id = b.fatura_id;

  if b.estado = 'pago' then
    return jsonb_build_object('ok', false, 'erro',
      'Este boleto já foi pago em ' || to_char(b.pago_em, 'DD/MM/YYYY') || '.');
  end if;
  if b.estado = 'cancelado' or f.estado = 'anulada' then
    return jsonb_build_object('ok', false, 'erro', 'Este boleto foi cancelado pelo emitente.');
  end if;
  if b.estado = 'em_pagamento' then
    return jsonb_build_object('ok', false, 'erro', 'Este boleto está à espera de aprovação interna.');
  end if;
  if not public.fn_cedula_minha(f.devedor_cedula) then
    return jsonb_build_object('ok', false, 'erro', 'Este boleto está em nome de outra entidade.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'descricao', descricao, 'quantidade', quantidade,
    'valor_unitario', valor_unitario, 'total', quantidade * valor_unitario) order by ordem), '[]'::jsonb)
  into v_linhas from public.fatura_linhas where fatura_id = f.id;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'entidade', b.entidade, 'referencia', b.referencia_mb,
    'linha', b.entidade || ' ' || substr(b.referencia_mb,1,3) || ' ' || substr(b.referencia_mb,4,3) || ' ' || substr(b.referencia_mb,7,3),
    'valor', b.valor, 'prazo', b.prazo, 'vencido', b.prazo < now(),
    'fatura', f.numero, 'descricao', f.descricao,
    'emitente_cedula', f.emitente_cedula,
    'emitente', (select coalesce(nome, f.emitente_cedula) from public.empresas where cedula = f.emitente_cedula),
    'linhas', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao consultar: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Pagar por entidade + referência
-- ---------------------------------------------------------------------
create or replace function public.banco_pagar_referencia(
  p_entidade text, p_referencia text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_consulta jsonb;
  b record; f record;
  v_origem text; v_destino text; v_res jsonb; v_estado text;
begin
  v_consulta := public.banco_consultar_boleto(p_entidade, p_referencia);
  if not (v_consulta->>'ok')::boolean then
    return v_consulta;
  end if;

  select * into b from public.boletos
    where entidade = regexp_replace(p_entidade, '\D', '', 'g')
      and referencia_mb = regexp_replace(p_referencia, '\D', '', 'g')
    for update;
  select * into f from public.faturas where id = b.fatura_id;

  select iban into v_origem from public.contas where cedula = f.devedor_cedula;
  select iban into v_destino from public.contas where cedula = f.emitente_cedula;
  if v_origem is null or v_destino is null then
    return jsonb_build_object('ok', false, 'erro', 'Falta conta do devedor ou do emitente.');
  end if;

  v_res := public.banco_transferir(v_origem, v_destino, b.valor,
    coalesce(f.servico, 'fatura'),
    'Boleto ' || b.entidade || '/' || b.referencia_mb || ' · fatura ' || f.numero);
  if not (v_res->>'ok')::boolean then
    return v_res;
  end if;
  v_estado := v_res->'dados'->>'estado';

  if v_estado = 'concluida' then
    update public.boletos set estado = 'pago', pago_em = now(),
      transacao_id = (v_res->'dados'->>'id')::uuid where id = b.id;
    update public.faturas set estado = 'paga', paga_em = now() where id = f.id;
  else
    update public.boletos set estado = 'em_pagamento',
      transacao_id = (v_res->'dados'->>'id')::uuid where id = b.id;
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'entidade', b.entidade, 'referencia', b.referencia_mb,
    'fatura', f.numero, 'valor', b.valor,
    'emitente', (select coalesce(nome, f.emitente_cedula) from public.empresas where cedula = f.emitente_cedula),
    'estado', case when v_estado = 'concluida' then 'pago' else 'em_pagamento' end,
    'transacao_id', v_res->'dados'->>'id',
    'codigo', v_res->'dados'->>'codigo',
    'aviso', case when v_estado <> 'concluida'
                  then 'Acima do limite: aguarda aprovação de um gerente.' end));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao pagar: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Cancelar — só o emitente, só em aberto
-- ---------------------------------------------------------------------
create or replace function public.banco_cancelar_boleto(p_referencia text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare b record; f record;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  select * into b from public.boletos
    where referencia_mb = regexp_replace(coalesce(p_referencia, ''), '\D', '', 'g') for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Boleto não encontrado.');
  end if;
  select * into f from public.faturas where id = b.fatura_id;

  if not public.fn_cedula_minha(f.emitente_cedula) then
    return jsonb_build_object('ok', false, 'erro', 'Só o emitente pode cancelar este boleto.');
  end if;
  if b.estado <> 'por_pagar' then
    return jsonb_build_object('ok', false, 'erro', 'Só é possível cancelar boletos em aberto.');
  end if;

  update public.boletos set estado = 'cancelado' where id = b.id;
  update public.faturas set estado = 'anulada' where id = f.id;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'referencia', b.referencia_mb, 'estado', 'cancelado'));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao cancelar: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Lista separada: o que tenho a pagar vs o que emiti
-- ---------------------------------------------------------------------
create or replace function public.banco_boletos(p_cedula text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_cedula text; v_a_pagar jsonb; v_emitidos jsonb;
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

  select coalesce(jsonb_agg(l order by (l->>'prazo')), '[]'::jsonb) into v_a_pagar
  from (
    select jsonb_build_object(
      'entidade', b.entidade, 'referencia', b.referencia_mb,
      'linha', b.entidade || ' ' || substr(b.referencia_mb,1,3) || ' ' || substr(b.referencia_mb,4,3) || ' ' || substr(b.referencia_mb,7,3),
      'fatura', f.numero, 'valor', b.valor, 'estado', b.estado,
      'prazo', b.prazo, 'vencido', b.prazo < now() and b.estado = 'por_pagar',
      'descricao', f.descricao,
      'contraparte', coalesce(e.nome, f.emitente_cedula)) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    left join public.empresas e on e.cedula = f.emitente_cedula
    where f.devedor_cedula = v_cedula and b.estado <> 'cancelado'
  ) s;

  select coalesce(jsonb_agg(l order by (l->>'prazo')), '[]'::jsonb) into v_emitidos
  from (
    select jsonb_build_object(
      'entidade', b.entidade, 'referencia', b.referencia_mb,
      'linha', b.entidade || ' ' || substr(b.referencia_mb,1,3) || ' ' || substr(b.referencia_mb,4,3) || ' ' || substr(b.referencia_mb,7,3),
      'fatura', f.numero, 'valor', b.valor, 'estado', b.estado,
      'prazo', b.prazo, 'vencido', b.prazo < now() and b.estado = 'por_pagar',
      'descricao', f.descricao,
      'contraparte', coalesce(e.nome, f.devedor_cedula)) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    left join public.empresas e on e.cedula = f.devedor_cedula
    where f.emitente_cedula = v_cedula
  ) s;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula, 'a_pagar', v_a_pagar, 'emitidos', v_emitidos));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao listar: ' || sqlerrm);
end;
$$;
