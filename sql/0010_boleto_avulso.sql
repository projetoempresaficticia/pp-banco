-- pp-banco — 0010 — emitir um boleto sem fatura
--
-- Correção de conceito, pedida pelo Germano (2026-09-04): "lembre que
-- fatura e boleto são diferentes". Estavam colados. A única forma de
-- criar um boleto era emitir uma fatura com linhas, e isso não é o que
-- se passa na vida real:
--
--   FATURA  diz O QUÊ e QUANTO, discriminado linha a linha. É o
--           documento comercial: 20 pães a 1,50, 12 bolos a 0,85.
--   BOLETO  é a ORDEM DE PAGAMENTO que sai daí: entidade, referência,
--           valor, prazo. É o instrumento com que se paga.
--
-- Uma fatura gera sempre um boleto. Mas um boleto **não** precisa de
-- fatura: uma cobrança avulsa (uma taxa, uma quota, um acerto) é só um
-- valor a pagar até uma data. Obrigar a discriminar linhas para cobrar
-- P$ 15 de uma taxa é papelada a mais.
--
-- Nota de implementação, para não haver ilusões: o boleto continua
-- pendurado numa linha de `faturas`, porque é aí que vive o rasto de
-- quem cobrou a quem, por quanto, e se foi pago. O que muda é que essa
-- linha fica marcada com `servico = 'boleto_avulso'` e leva uma só
-- linha de detalhe. Assim os documentos e as listas conseguem dizer a
-- verdade sobre o que estão a mostrar, em vez de chamarem "fatura" a
-- uma coisa que o utilizador nunca pediu.

create or replace function public.banco_emitir_boleto(
  p_devedor   text,
  p_descricao text,
  p_valor     bigint,
  p_dias      int default 30
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emitente text;
  v_res jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  v_emitente := public.fn_minha_empresa_cedula();
  if v_emitente is null then
    return jsonb_build_object('ok', false, 'erro',
      'Só quem está vinculado a uma empresa pode emitir boletos.');
  end if;

  if p_valor is null or p_valor <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'O valor tem de ser positivo.');
  end if;
  if btrim(coalesce(p_descricao, '')) = '' then
    return jsonb_build_object('ok', false, 'erro', 'Escreva para que serve a cobrança.');
  end if;

  -- Uma linha só, com o próprio texto da cobrança, e `servico` marcado
  -- já na criação: a `banco_emitir_fatura_interna` recebe esse campo,
  -- por isso não é preciso voltar atrás com um update.
  v_res := public.banco_emitir_fatura_interna(
    v_emitente,
    btrim(p_devedor),
    btrim(p_descricao),
    jsonb_build_array(jsonb_build_object(
      'descricao', btrim(p_descricao),
      'quantidade', 1,
      'valor_unitario', p_valor)),
    p_dias, 'boleto_avulso', null);

  if not (v_res->>'ok')::boolean then
    return v_res;
  end if;

  return jsonb_build_object('ok', true,
    'dados', (v_res->'dados') || jsonb_build_object('avulso', true));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível emitir o boleto.');
end;
$$;

comment on function public.banco_emitir_boleto(text, text, bigint, int) is
  'Cobrança avulsa: um boleto sem fatura discriminada. Continua a assentar '
  'numa linha de faturas (é lá que vive o rasto), marcada com '
  'servico = boleto_avulso para os ecrãs não lhe chamarem fatura.';

revoke execute on function public.banco_emitir_boleto(text, text, bigint, int) from public, anon;
grant  execute on function public.banco_emitir_boleto(text, text, bigint, int) to authenticated;

-- Os ecrãs e o documento precisam de saber distinguir os dois. Sem isto
-- um boleto avulso saía impresso com o cabeçalho de uma fatura.
create or replace function public.banco_boleto_documento(p_entidade text, p_referencia text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_ent text := regexp_replace(coalesce(p_entidade, ''), '\D', '', 'g');
  v_ref text := regexp_replace(coalesce(p_referencia, ''), '\D', '', 'g');
  b record; f record; v_linhas jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if length(v_ent) <> 5 or length(v_ref) <> 9 then
    return jsonb_build_object('ok', false, 'erro', 'Entidade ou referência mal formada.');
  end if;

  select * into b from public.boletos where entidade = v_ent and referencia_mb = v_ref;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Não existe nenhum boleto com esta referência.');
  end if;
  select * into f from public.faturas where id = b.fatura_id;

  if not (public.fn_cedula_minha(f.devedor_cedula)
          or public.fn_cedula_minha(f.emitente_cedula)
          or public.fn_e_professor()) then
    return jsonb_build_object('ok', false, 'erro', 'Este boleto não lhe diz respeito.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'descricao', descricao, 'quantidade', quantidade,
    'valor_unitario', valor_unitario, 'total', quantidade * valor_unitario) order by ordem), '[]'::jsonb)
  into v_linhas from public.fatura_linhas where fatura_id = f.id;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'entidade', b.entidade, 'referencia', b.referencia_mb, 'valor', b.valor,
    'prazo', b.prazo, 'vencido', b.estado = 'por_pagar' and b.prazo < now(),
    'estado', b.estado, 'pago_em', b.pago_em, 'emitido_em', b.emitido_em,
    'fatura', f.numero, 'descricao', f.descricao,
    'avulso', f.servico is not distinct from 'boleto_avulso',
    'emitente_cedula', f.emitente_cedula, 'emitente', public.fn_nome_de(f.emitente_cedula),
    'devedor_cedula', f.devedor_cedula, 'devedor', public.fn_nome_de(f.devedor_cedula),
    'linhas', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível montar o documento.');
end;
$$;

-- O mesmo na consulta de quem vai pagar, para o painel de confirmação
-- não mostrar uma linha de detalhe inventada num boleto avulso.
create or replace function public.banco_consultar_boleto(p_entidade text, p_referencia text)
returns jsonb language plpgsql security definer set search_path = public
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
    'avulso', f.servico is not distinct from 'boleto_avulso',
    'emitente_cedula', f.emitente_cedula, 'emitente', public.fn_nome_de(f.emitente_cedula),
    'linhas', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao consultar o boleto.');
end;
$$;

-- E nas listas, para a aba "Emitidos por mim" separar os dois.
create or replace function public.banco_boletos(p_cedula text default null)
returns jsonb language plpgsql security definer set search_path = public
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
      'descricao', f.descricao, 'fatura_id', f.id,
      'avulso', f.servico is not distinct from 'boleto_avulso',
      'contraparte', public.fn_nome_de(f.emitente_cedula)) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    where f.devedor_cedula = v_cedula and b.estado <> 'cancelado'
  ) s;

  select coalesce(jsonb_agg(l order by (l->>'prazo')), '[]'::jsonb) into v_emitidos
  from (
    select jsonb_build_object(
      'entidade', b.entidade, 'referencia', b.referencia_mb,
      'linha', b.entidade || ' ' || substr(b.referencia_mb,1,3) || ' ' || substr(b.referencia_mb,4,3) || ' ' || substr(b.referencia_mb,7,3),
      'fatura', f.numero, 'valor', b.valor, 'estado', b.estado,
      'prazo', b.prazo, 'vencido', b.prazo < now() and b.estado = 'por_pagar',
      'descricao', f.descricao, 'fatura_id', f.id,
      'avulso', f.servico is not distinct from 'boleto_avulso',
      'contraparte', public.fn_nome_de(f.devedor_cedula)) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    where f.emitente_cedula = v_cedula
  ) s;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula, 'a_pagar', v_a_pagar, 'emitidos', v_emitidos));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível listar os boletos.');
end;
$$;
