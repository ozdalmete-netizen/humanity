CREATE OR REPLACE FUNCTION public.reserve_batch_atomic(p_canvas text, p_items jsonb, p_token_hash text, p_created_ip_hash text DEFAULT NULL::text, p_ttl_seconds integer DEFAULT 420)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
declare
  v_canvas public.canvas_kind;
  v_width integer;
  v_height integer;
  v_unlocked boolean;
  v_count integer;
  v_batch_id uuid;
  v_expires timestamptz;
  v_conflicts jsonb;
  v_row record;
begin
  begin
    v_canvas := p_canvas::public.canvas_kind;
  exception when others then
    return jsonb_build_object('ok',false,'code','INVALID_CANVAS');
  end;

  if jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok',false,'code','INVALID_ITEMS');
  end if;

  v_count := jsonb_array_length(p_items);
  if v_count < 1 or v_count > 1000 then
    return jsonb_build_object('ok',false,'code','INVALID_ITEM_COUNT');
  end if;

  if p_ttl_seconds < 60 or p_ttl_seconds > 900 then
    return jsonb_build_object('ok',false,'code','INVALID_TTL');
  end if;

  if p_token_hash is null or length(p_token_hash) <> 64 then
    return jsonb_build_object('ok',false,'code','INVALID_TOKEN_HASH');
  end if;

  select width,height,unlocked into v_width,v_height,v_unlocked
  from public.canvas_state where canvas=v_canvas for share;

  if not found then return jsonb_build_object('ok',false,'code','INVALID_CANVAS'); end if;
  if not v_unlocked then return jsonb_build_object('ok',false,'code','CANVAS_LOCKED'); end if;

  if exists (
    select 1 from jsonb_to_recordset(p_items) as i(x integer,y integer,color_id integer)
    where i.x is null or i.y is null or i.color_id is null
       or i.x < 0 or i.x >= v_width
       or i.y < 0 or i.y >= v_height
       or i.color_id < 1 or i.color_id > 32
  ) then
    return jsonb_build_object('ok',false,'code','INVALID_CELL');
  end if;

  if (
    select count(*) from (
      select i.x,i.y
      from jsonb_to_recordset(p_items) as i(x integer,y integer,color_id integer)
      group by i.x,i.y
    ) d
  ) <> v_count then
    return jsonb_build_object('ok',false,'code','DUPLICATE_CELL');
  end if;

  for v_row in
    select i.x,i.y
    from jsonb_to_recordset(p_items) as i(x integer,y integer,color_id integer)
    order by (i.y::bigint * v_width::bigint + i.x::bigint)
  loop
    perform pg_advisory_xact_lock(hashtext(v_canvas::text),(v_row.y * v_width + v_row.x));
  end loop;

  delete from public.reservation_cells r
  using jsonb_to_recordset(p_items) as i(x integer,y integer,color_id integer)
  where r.canvas=v_canvas and r.x=i.x and r.y=i.y and r.expires_at <= now();

  update public.checkout_batches
  set status='expired',updated_at=now()
  where status in ('reserved','prepared') and expires_at <= now();

  select coalesce(jsonb_agg(jsonb_build_object('x',q.x,'y',q.y,'reason',q.reason) order by q.y,q.x),'[]'::jsonb)
  into v_conflicts
  from (
    select i.x,i.y,
      case when exists(select 1 from public.marks m where m.canvas=v_canvas and m.x=i.x and m.y=i.y)
           then 'sealed' else 'reserved' end as reason
    from jsonb_to_recordset(p_items) as i(x integer,y integer,color_id integer)
    where exists(select 1 from public.marks m where m.canvas=v_canvas and m.x=i.x and m.y=i.y)
       or exists(select 1 from public.reservation_cells r where r.canvas=v_canvas and r.x=i.x and r.y=i.y and r.expires_at>now())
  ) q;

  if jsonb_array_length(v_conflicts) > 0 then
    return jsonb_build_object('ok',false,'code','CELL_CONFLICT','conflicts',v_conflicts);
  end if;

  v_expires := now()+make_interval(secs=>p_ttl_seconds);

  insert into public.checkout_batches(
    canvas,reservation_token_hash,created_ip_hash,item_count,
    unit_price_minor,amount_minor,currency,status,expires_at
  ) values (
    v_canvas,p_token_hash,p_created_ip_hash,v_count,
    499,v_count*499,'USD','reserved',v_expires
  ) returning id into v_batch_id;

  insert into public.batch_cells(batch_id,canvas,x,y,color_id)
  select v_batch_id,v_canvas,i.x,i.y,i.color_id
  from jsonb_to_recordset(p_items) as i(x integer,y integer,color_id integer);

  insert into public.reservation_cells(canvas,x,y,batch_id,color_id,expires_at)
  select v_canvas,i.x,i.y,v_batch_id,i.color_id,v_expires
  from jsonb_to_recordset(p_items) as i(x integer,y integer,color_id integer);

  return jsonb_build_object(
    'ok',true,'batch_id',v_batch_id,'expires_at',v_expires,
    'item_count',v_count,'amount_minor',v_count*499,'currency','USD'
  );
end;
$function$;
