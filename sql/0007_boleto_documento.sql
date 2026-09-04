-- pp-banco — 0007 — a porta do documento imprimível
--
-- Porquê: `banco_consultar_boleto` é do lado de quem paga — recusa
-- qualquer boleto que não esteja em nome do consulente, e recusa também
-- os já pagos ou cancelados. É o comportamento certo para o ecrã de
-- pagamento, mas errado para o papel: quem emitiu tem de poder imprimir
-- e reenviar o boleto, e um boleto pago tem de continuar a poder ser
-- reimpresso.
--
-- Sem esta porta, o `documento.html` caía numa lista com outra forma de
-- dados, e imprimia a cédula do devedor debaixo do rótulo "Emitente" —
-- porque "contraparte" quer dizer coisas opostas conforme quem olha. Um
-- documento não pode ter campos que mudam de significado com o leitor:
-- aqui devolvem-se sempre os dois lados, com nome e cédula.
--
-- Também resolve o nome em `pessoas` além de `empresas`: uma pessoa pode
-- emitir e receber faturas, e antes disto saía a cédula crua no papel.

-- Nome público de uma cédula, seja pessoa ou empresa. Devolve a própria
-- cédula se não encontrar — o documento nunca fica com um campo vazio.
create or replace function public.fn_nome_de(p_cedula text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select nome from public.empresas where cedula = p_cedula),
    (select nome from public.pessoas  where cedula = p_cedula),
    p_cedula);
$$;

revoke execute on function public.fn_nome_de(text) from public, anon;
grant  execute on function public.fn_nome_de(text) to authenticated;

create or replace function public.banco_boleto_documento(
  p_entidade text,
  p_referencia text
) returns jsonb
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
  if length(v_ent) <> 5 or length(v_ref) <> 9 then
    return jsonb_build_object('ok', false, 'erro', 'Entidade ou referência mal formada.');
  end if;

  select * into b from public.boletos where entidade = v_ent and referencia_mb = v_ref;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Não existe nenhum boleto com esta referência.');
  end if;
  select * into f from public.faturas where id = b.fatura_id;

  -- só as duas partes (e o professor) veem o documento
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
    'entidade', b.entidade,
    'referencia', b.referencia_mb,
    'valor', b.valor,
    'prazo', b.prazo,
    'vencido', b.estado = 'por_pagar' and b.prazo < now(),
    'estado', b.estado,
    'pago_em', b.pago_em,
    'emitido_em', b.emitido_em,
    'fatura', f.numero,
    'descricao', f.descricao,
    'emitente_cedula', f.emitente_cedula,
    'emitente', public.fn_nome_de(f.emitente_cedula),
    'devedor_cedula', f.devedor_cedula,
    'devedor', public.fn_nome_de(f.devedor_cedula),
    'linhas', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível montar o documento.');
end;
$$;

comment on function public.banco_boleto_documento(text, text) is
  'Boleto para impressão: serve emitente e devedor, e continua a servir '
  'depois de pago. Devolve sempre os dois lados com nome e cédula.';

revoke execute on function public.banco_boleto_documento(text, text) from public, anon;
grant  execute on function public.banco_boleto_documento(text, text) to authenticated;

-- E que o ecrã de pagamento também resolva nomes de pessoas, não só de
-- empresas: `banco_consultar_boleto` usava um select direto a `empresas`
-- e mostrava a cédula crua quando quem emitia era uma pessoa.
create or replace function public.banco_consultar_boleto(p_entidade text, p_referencia text)
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
    'emitente', public.fn_nome_de(f.emitente_cedula),
    'linhas', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao consultar o boleto.');
end;
$$;
