'use client';
import {useEffect,useMemo,useState} from 'react';
import {getSupabase} from '../lib/supabase';
import type {User} from '@supabase/supabase-js';
import {LayoutDashboard,Users,CalendarDays,ClipboardList,Wallet,Plus,PartyPopper,Trash2,Search,ArrowRight,CheckCircle2,AlertTriangle} from 'lucide-react';
type Client={id:string;name:string;phone:string;source:string};
type Order={id:string;clientId:string;program:string;date:string;start:string;duration:number;price:number;status:'lead'|'pending'|'confirmed'|'done'|'cancelled';staff:string;costume:string;location:string};
type Payment={id:string;orderId:string;amount:number;date:string;kind:'payment'|'refund';note:string};
type Store={clients:Client[];orders:Order[];payments:Payment[]};
const seed:Store={clients:[],orders:[],payments:[]};
const money=(n:number)=>new Intl.NumberFormat('ru-RU').format(n)+' сум';
const nav=[{key:'dashboard',label:'Обзор',icon:LayoutDashboard},{key:'clients',label:'Клиенты',icon:Users},{key:'orders',label:'Заказы',icon:ClipboardList},{key:'calendar',label:'Календарь',icon:CalendarDays},{key:'payments',label:'Платежи',icon:Wallet}] as const;
type Tab=typeof nav[number]['key'];
const statLabel:Record<Order['status'],string>={lead:'Новая заявка',pending:'Ожидает оплаты',confirmed:'Подтверждён',done:'Выполнен',cancelled:'Отменён'};
const nextId=(prefix:string)=>`${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2,6)}`;
const overlap=(a:Order,b:Order)=>a.date===b.date&&a.start<bEnd(b)&&b.start<bEnd(a);
function bEnd(o:Order){const [h,m]=o.start.split(':').map(Number);return `${String(Math.floor((h*60+m+o.duration)/60)).padStart(2,'0')}:${String((h*60+m+o.duration)%60).padStart(2,'0')}`}
export default function Home(){
 const [tab,setTab]=useState<Tab>('dashboard'); const [store,setStore]=useState<Store>(seed);
 const [user,setUser]=useState<User|null>(null);const [authLoading,setAuthLoading]=useState(true);const [busy,setBusy]=useState(false);const [email,setEmail]=useState('');const [password,setPassword]=useState('');const [authError,setAuthError]=useState('');
 const [clientForm,setClientForm]=useState(false);const [orderForm,setOrderForm]=useState(false);const [orderClientMode,setOrderClientMode]=useState<'existing'|'new'>('existing');const [paymentForm,setPaymentForm]=useState(false);
 const [search,setSearch]=useState(''); const [month,setMonth]=useState(()=>new Date().toISOString().slice(0,7));const [alert,setAlert]=useState('');
 const [client,setClient]=useState({name:'',phone:'',source:'Instagram'});
 const [order,setOrder]=useState({clientId:'',program:'День рождения',date:'',start:'16:00',duration:'60',price:'800000',staff:'',costume:'',location:''});
 const [payment,setPayment]=useState({orderId:'',amount:'',date:new Date().toISOString().slice(0,10),kind:'payment' as 'payment'|'refund',note:''});
 useEffect(()=>{
  const db=getSupabase();
  if(!db){setAuthError('Не заданы переменные Supabase. См. README.');setAuthLoading(false);return;}
  let live=true;
  db.auth.getUser().then(({data,error})=>{
    if(!live)return;
    if(error && error.name!=='AuthSessionMissingError')setAuthError(error.message);
    setUser(data.user||null);setAuthLoading(false);
  });
  const {data:{subscription}}=db.auth.onAuthStateChange((_event,session)=>{if(live)setUser(session?.user||null)});
  return ()=>{live=false;subscription.unsubscribe()};
 },[]);
 async function refresh(){
  const db=getSupabase();if(!db)return;
  const [c,o,p]=await Promise.all([
    db.from('clients').select('id,name,phone,source').order('created_at',{ascending:false}),
    db.from('orders').select('*').order('event_date',{ascending:true}),
    db.from('payments').select('*').order('created_at',{ascending:false})
  ]);
  const err=c.error||o.error||p.error;
  if(err){setAlert('Не удалось получить данные: '+err.message+'. Проверьте staff_profiles и RLS.');return;}
  setStore({
    clients:(c.data||[]).map(x=>({id:x.id,name:x.name,phone:x.phone,source:x.source})),
    orders:(o.data||[]).map(x=>({id:x.id,clientId:x.client_id,program:x.program,date:x.event_date,start:String(x.start_time).slice(0,5),duration:x.duration_minutes,price:Number(x.price_uzs),status:x.status,staff:x.staff||'',costume:x.costume||'',location:x.location||''})),
    payments:(p.data||[]).map(x=>({id:x.id,orderId:x.order_id,amount:Number(x.amount_uzs),date:x.payment_date,kind:x.kind,note:x.note||''}))
  });
 }
 useEffect(()=>{if(user)void refresh();else setStore(seed)},[user]);
 async function signIn(e:React.FormEvent){e.preventDefault();const db=getSupabase();if(!db)return;setAuthError('');setBusy(true);try{
  const {error}=await db.auth.signInWithPassword({email,password});if(error)throw error;
 }catch(e){setAuthError(errorText(e))}finally{setBusy(false)}}
 async function signOut(){await getSupabase()?.auth.signOut()}
 const errorText=(e:unknown)=>e instanceof Error?e.message:'Неизвестная ошибка';
 const totals=useMemo(()=>{const paid=store.payments.reduce((s,p)=>s+(p.kind==='refund'?-p.amount:p.amount),0);const booked=store.orders.filter(o=>!['cancelled','lead'].includes(o.status)).reduce((s,o)=>s+o.price,0);return {paid,booked,remaining:booked-paid}},[store]);
 const paidFor=(id:string)=>store.payments.filter(p=>p.orderId===id).reduce((s,p)=>s+(p.kind==='refund'?-p.amount:p.amount),0);
 const nameOf=(id:string)=>store.clients.find(c=>c.id===id)?.name||'Клиент не найден';
 const orderInfo=(id:string)=>store.orders.find(o=>o.id===id);
 async function addClient(e:React.FormEvent){
  e.preventDefault();if(!client.name.trim()||!client.phone.trim()||!user)return;
  const db=getSupabase();if(!db)return;setBusy(true);setAlert('');
  try{const {error}=await db.from('clients').insert({name:client.name.trim(),phone:client.phone.trim(),source:client.source,created_by:user.id});if(error)throw error;
   await refresh();setClient({name:'',phone:'',source:'Instagram'});setClientForm(false);
  }catch(e){setAlert('Клиент не сохранён: '+errorText(e))}finally{setBusy(false)}
 }
 async function addOrder(e:React.FormEvent){
  e.preventDefault();if(!user)return;
  const db=getSupabase();if(!db)return;
  const newMode=orderClientMode==='new';
  if(newMode&&(!client.name.trim()||!client.phone.trim())){setAlert('Укажите имя и телефон нового клиента');return}
  if(!order.date||!order.location.trim()||!Number(order.price)||!Number(order.duration)){setAlert('Укажите дату, место, цену и длительность');return}
  if(!newMode&&!order.clientId){setAlert('Выберите клиента');return}
  const proposed:Order={id:'',clientId:order.clientId,program:order.program,date:order.date,start:order.start,duration:Number(order.duration),price:Number(order.price),status:'pending',staff:order.staff,costume:order.costume,location:order.location};
  const conflict=store.orders.find(x=>!['cancelled','lead'].includes(x.status)&&overlap(x,proposed)&&((x.staff&&proposed.staff&&x.staff.toLowerCase()===proposed.staff.toLowerCase())||(x.costume&&proposed.costume&&x.costume.toLowerCase()===proposed.costume.toLowerCase())));
  if(conflict){setAlert(`Конфликт с заказом ${conflict.id}: занят аниматор или костюм.`);return}
  setBusy(true);setAlert('');
  try{
    let clientId=order.clientId;
    if(newMode){const {data,error}=await db.from('clients').insert({name:client.name.trim(),phone:client.phone.trim(),source:client.source,created_by:user.id}).select('id').single();if(error)throw error;clientId=data.id;}
    const {error}=await db.from('orders').insert({client_id:clientId,program:order.program,event_date:order.date,start_time:order.start,duration_minutes:Number(order.duration),price_uzs:Number(order.price),status:'pending',staff:order.staff,costume:order.costume,location:order.location.trim(),created_by:user.id});if(error)throw error;
    await refresh();setOrderForm(false);setOrderClientMode('existing');setClient({name:'',phone:'',source:'Instagram'});
    setOrder({clientId:'',program:'День рождения',date:'',start:'16:00',duration:'60',price:'800000',staff:'',costume:'',location:''});
  }catch(e){setAlert('Заказ не сохранён: '+errorText(e))}finally{setBusy(false)}
 }
 async function addPayment(e:React.FormEvent){
  e.preventDefault();if(!user)return;const db=getSupabase();if(!db)return;
  const amount=Number(payment.amount);if(!payment.orderId||!Number.isSafeInteger(amount)||amount<=0){setAlert('Укажите корректную сумму');return}
  const current=store.orders.find(o=>o.id===payment.orderId);
  if(!current||current.status==='cancelled'){setAlert('Нельзя провести платеж по отменённому заказу');return}
  const previous=store.payments.filter(p=>p.orderId===payment.orderId).reduce((s,p)=>s+(p.kind==='refund'?-p.amount:p.amount),0);
  if(payment.kind==='payment'&&previous+amount>current.price){setAlert('Оплата превышает сумму заказа');return}
  if(payment.kind==='refund'&&amount>previous){setAlert('Возврат превышает полученную сумму');return}
  setBusy(true);setAlert('');try{const {error}=await db.from('payments').insert({order_id:payment.orderId,amount_uzs:amount,payment_date:payment.date,kind:payment.kind,note:payment.note,created_by:user.id});if(error)throw error;
    await refresh();setPaymentForm(false);setPayment(p=>({...p,orderId:'',amount:'',note:''}));
  }catch(e){setAlert('Платёж не сохранён: '+errorText(e))}finally{setBusy(false)}
 }
 async function setStatus(id:string,status:Order['status']){const db=getSupabase();if(!db)return;const {error}=await db.from('orders').update({status}).eq('id',id);if(error)setAlert('Не удалось изменить статус: '+error.message);else await refresh()}
 const displayedOrders=store.orders.filter(o=>(o.id+' '+nameOf(o.clientId)+' '+o.program).toLowerCase().includes(search.toLowerCase()));
 const first=new Date(Number(month.slice(0,4)),Number(month.slice(5,7))-1,1);const daysInMonth=new Date(first.getFullYear(),first.getMonth()+1,0).getDate();const offset=(first.getDay()+6)%7;
 if(authLoading)return <div className="authPage"><div className="authCard">Подключаем BEST Animator CRM…</div></div>;
 if(!user)return <div className="authPage"><div className="authCard"><div className="authBrand">🎉 BEST Animator</div><h1>Вход в CRM</h1><p>Единые заказы и платежи доступны только сотрудникам.</p><form onSubmit={signIn} className="form"><Field label="Email сотрудника"><input required type="email" autoComplete="username" value={email} onChange={e=>setEmail(e.target.value)}/></Field><Field label="Пароль"><input required type="password" autoComplete="current-password" value={password} onChange={e=>setPassword(e.target.value)}/></Field>{authError&&<p className="authError">{authError}</p>}<button className="primary" disabled={busy}>{busy?'Входим…':'Войти'}</button></form><small>Учетные записи создаёт администратор Supabase.</small></div></div>;
 return <div className="shell"><aside className="sidebar"><div className="logo"><div className="logoIcon"><PartyPopper size={24}/></div><div><strong>BEST Animator</strong><small>CRM / cloud v0.3</small></div></div><div className="nav">{nav.map(({key,label,icon:Icon})=><button key={key} className={tab===key?'navitem active':'navitem'} onClick={()=>{setTab(key);setSearch('')}}><Icon size={19}/>{label}</button>)}</div><div className="sidebottom">Облачная CRM<br/>Данные хранятся в Supabase.<br/>Доступ только для авторизованных сотрудников.</div></aside>
 <main className="main"><div className="topbar"><div><span className="eyebrow">ОПЕРАЦИОННАЯ ПАНЕЛЬ</span><h1>{nav.find(n=>n.key===tab)?.label}</h1></div><div className="right"><span className="pill">● Облако</span><button className="ghost" onClick={signOut}>Выйти</button><span className="userAvatar">BA</span></div></div>
 {alert&&<div className="alert"><AlertTriangle size={18}/>{alert}<button onClick={()=>setAlert('')}>×</button></div>}
 {tab==='dashboard'&&<><div className="intro"><div><h2>Управление мероприятиями без хаоса</h2><p>Контролируйте заявки, бронирования, клиентов и оплаты в одном месте.</p></div><button className="primary" onClick={()=>{setTab('orders');setOrderForm(true)}}><Plus size={18}/> Новый заказ</button></div><div className="stats"><Kpi label="Клиентов в базе" value={String(store.clients.length)} icon={<Users size={22}/>}/><Kpi label="Заказов" value={String(store.orders.length)} icon={<ClipboardList size={22}/>}/><Kpi label="Получено оплат" value={money(totals.paid)} icon={<Wallet size={22}/>}/><Kpi label="Остаток по броням" value={money(totals.remaining)} icon={<CalendarDays size={22}/>}/></div><section className="panel"><div className="sectionheading"><h3>Ближайшие мероприятия</h3><button className="ghost" onClick={()=>setTab('calendar')}>Открыть календарь <ArrowRight size={16}/></button></div><OrderTable orders={store.orders.filter(o=>o.status!=='cancelled').sort((a,b)=>(a.date+a.start).localeCompare(b.date+b.start)).slice(0,6)} nameOf={nameOf} paidFor={paidFor} setStatus={setStatus}/></section></>}
 {tab==='clients'&&<section className="panel"><div className="sectionheading"><div><h3>Клиенты</h3><p className="muted">Контакты и источники обращений</p></div><button className="primary" onClick={()=>setClientForm(true)}><Plus size={18}/> Добавить клиента</button></div><div className="tablewrap"><table><thead><tr><th>Клиент</th><th>Телефон</th><th>Источник</th><th>Заказов</th></tr></thead><tbody>{store.clients.map(c=><tr key={c.id}><td className="strong">{c.name}</td><td>{c.phone}</td><td>{c.source}</td><td>{store.orders.filter(o=>o.clientId===c.id).length}</td></tr>)}</tbody></table></div></section>}
 {tab==='orders'&&<section className="panel"><div className="sectionheading"><div><h3>Заказы и бронирования</h3><p className="muted">Все заявки и мероприятия</p></div><button className="primary" onClick={()=>setOrderForm(true)}><Plus size={18}/> Новый заказ</button></div><div className="search"><Search size={17}/><input placeholder="Поиск по клиенту, программе, номеру" value={search} onChange={e=>setSearch(e.target.value)}/></div><OrderTable orders={displayedOrders} nameOf={nameOf} paidFor={paidFor} setStatus={setStatus}/></section>}
 {tab==='calendar'&&<section className="panel"><div className="sectionheading"><div><h3>Календарь мероприятий</h3><p className="muted">Планирование заказов по дням</p></div><input aria-label="Месяц" type="month" value={month} onChange={e=>setMonth(e.target.value)}/></div><div className="calendar">{['Пн','Вт','Ср','Чт','Пт','Сб','Вс'].map(d=><div className="dayhead" key={d}>{d}</div>)}{Array.from({length:offset},(_,i)=><div key={'x'+i} className="day empty"/>)}{Array.from({length:daysInMonth},(_,i)=>{const d=`${month}-${String(i+1).padStart(2,'0')}`;const events=store.orders.filter(o=>o.date===d&&o.status!=='cancelled');return <div className="day" key={d}><span className="daynum">{i+1}</span>{events.map(o=><div className="event" key={o.id} title={`${nameOf(o.clientId)} — ${o.program}`}>{o.start} {o.program}</div>)}</div>})}</div></section>}
 {tab==='payments'&&<section className="panel"><div className="sectionheading"><div><h3>Учёт платежей</h3><p className="muted">Поступления, возвраты и история операций</p></div><button className="primary" onClick={()=>setPaymentForm(true)}><Plus size={18}/> Записать платёж</button></div><div className="stats compact"><Kpi label="Поступления за всё время" value={money(store.payments.filter(p=>p.kind==='payment').reduce((s,p)=>s+p.amount,0))}/><Kpi label="Возвраты" value={money(store.payments.filter(p=>p.kind==='refund').reduce((s,p)=>s+p.amount,0))}/><Kpi label="Чистое поступление" value={money(totals.paid)}/></div><div className="tablewrap"><table><thead><tr><th>Дата</th><th>Заказ</th><th>Клиент</th><th>Место мероприятия</th><th>Тип</th><th>Сумма</th><th>Примечание</th></tr></thead><tbody>{store.payments.map(p=><tr key={p.id}><td>{p.date}</td><td>{p.orderId}</td><td>{nameOf(orderInfo(p.orderId)?.clientId||'')}</td><td>{orderInfo(p.orderId)?.location||'Не указано'}</td><td>{p.kind==='payment'?'Оплата':'Возврат'}</td><td className="strong">{p.kind==='refund'?'-':''}{money(p.amount)}</td><td>{p.note||'—'}</td></tr>)}</tbody></table>{store.payments.length===0&&<Empty label="Платежей пока нет"/>}</div></section>}
 </main>
 {clientForm&&<Modal title="Новый клиент" close={()=>setClientForm(false)}><form onSubmit={addClient} className="form"><Field label="Имя клиента"><input required value={client.name} onChange={e=>setClient({...client,name:e.target.value})} placeholder="Имя или организация"/></Field><Field label="Телефон"><input required value={client.phone} onChange={e=>setClient({...client,phone:e.target.value})} placeholder="+998 ..."/></Field><Field label="Источник"><select value={client.source} onChange={e=>setClient({...client,source:e.target.value})}>{['Instagram','Телефон','Рекомендация','WhatsApp','Другое'].map(x=><option key={x}>{x}</option>)}</select></Field><button className="primary" disabled={busy} type="submit">{busy?'Сохраняем…':'Сохранить клиента'}</button></form></Modal>}
 {orderForm&&<Modal title="Новое бронирование" close={()=>{setOrderForm(false);setAlert('')}}><form onSubmit={addOrder} className="form"><div className="clientChoice"><span className="choiceTitle">Клиент</span><div className="switchClient"><button type="button" className={orderClientMode==='existing'?'switchActive':''} onClick={()=>setOrderClientMode('existing')}>Выбрать существующего</button><button type="button" className={orderClientMode==='new'?'switchActive':''} onClick={()=>setOrderClientMode('new')}><Plus size={15}/> Новый клиент</button></div></div>
 {orderClientMode==='existing'?<Field label="Клиент из базы"><select required value={order.clientId} onChange={e=>setOrder({...order,clientId:e.target.value})}><option value="">Выберите клиента</option>{store.clients.map(c=><option key={c.id} value={c.id}>{c.name} · {c.phone}</option>)}</select></Field>:<div className="inlineClient"><Field label="Имя клиента / организация"><input required autoFocus value={client.name} onChange={e=>setClient({...client,name:e.target.value})} placeholder="Например: Малика"/></Field><Field label="Телефон"><input required type="tel" value={client.phone} onChange={e=>setClient({...client,phone:e.target.value})} placeholder="+998 90 123 45 67"/></Field><Field label="Источник заявки"><select value={client.source} onChange={e=>setClient({...client,source:e.target.value})}>{['Instagram','Телефон','Рекомендация','WhatsApp','Другое'].map(x=><option key={x}>{x}</option>)}</select></Field><p className="hint">Клиент будет добавлен в базу автоматически при сохранении заказа.</p></div>}<Field label="Программа"><select value={order.program} onChange={e=>setOrder({...order,program:e.target.value})}>{['День рождения','Экспресс-поздравление','Праздник PLUS','Большое шоу','Новогодняя программа','Корпоратив'].map(x=><option key={x}>{x}</option>)}</select></Field><div className="two"><Field label="Дата"><input required type="date" value={order.date} onChange={e=>setOrder({...order,date:e.target.value})}/></Field><Field label="Начало"><input type="time" required value={order.start} onChange={e=>setOrder({...order,start:e.target.value})}/></Field></div><div className="two"><Field label="Длительность, мин"><input required type="number" min="15" max="480" value={order.duration} onChange={e=>setOrder({...order,duration:e.target.value})}/></Field><Field label="Стоимость, сум"><input required type="number" min="1" value={order.price} onChange={e=>setOrder({...order,price:e.target.value})}/></Field></div><Field label="Аниматор / команда"><input value={order.staff} onChange={e=>setOrder({...order,staff:e.target.value})} placeholder="Например: Аниматор 1"/></Field><Field label="Костюм"><input value={order.costume} onChange={e=>setOrder({...order,costume:e.target.value})} placeholder="Например: Мишка"/></Field><Field label="Место проведения"><input value={order.location} onChange={e=>setOrder({...order,location:e.target.value})}/></Field><p className="hint">Проверка занятости пока предварительная. Окончательная серверная блокировка пересечений планируется отдельно.</p><button className="primary" disabled={busy} type="submit">{busy?'Сохраняем…':'Создать заказ'}</button></form></Modal>}
 {paymentForm&&<Modal title="Записать платёж" close={()=>setPaymentForm(false)}><form onSubmit={addPayment} className="form"><Field label="Мероприятие — клиент и место"><select required value={payment.orderId} onChange={e=>setPayment({...payment,orderId:e.target.value})}><option value="">Выберите заказ</option>{store.orders.map(o=><option key={o.id} value={o.id}>{nameOf(o.clientId)} — {o.location||'Место не указано'} · {o.date} ({o.id})</option>)}</select></Field><div className="two"><Field label="Сумма, сум"><input required min="1" type="number" value={payment.amount} onChange={e=>setPayment({...payment,amount:e.target.value})}/></Field><Field label="Дата"><input required type="date" value={payment.date} onChange={e=>setPayment({...payment,date:e.target.value})}/></Field></div><Field label="Тип"><select value={payment.kind} onChange={e=>setPayment({...payment,kind:e.target.value as 'payment'|'refund'})}><option value="payment">Оплата</option><option value="refund">Возврат</option></select></Field><Field label="Примечание"><input value={payment.note} onChange={e=>setPayment({...payment,note:e.target.value})} placeholder="Предоплата / остаток"/></Field><button className="primary" disabled={busy}>{busy?'Сохраняем…':'Записать операцию'}</button></form></Modal>}
 </div>
}
function Kpi({label,value,icon}:{label:string;value:string;icon?:React.ReactNode}){return <div className="kpi"><span className="kpiTop">{label}{icon}</span><strong>{value}</strong></div>}
function Field({label,children}:{label:string;children:React.ReactNode}){return <label className="field"><span>{label}</span>{children}</label>}
function Modal({title,children,close}:{title:string;children:React.ReactNode;close:()=>void}){return <div className="overlay" onMouseDown={e=>{if(e.target===e.currentTarget)close()}}><div className="modal"><div className="modalhead"><h3>{title}</h3><button onClick={close} aria-label="Закрыть">×</button></div>{children}</div></div>}
function Empty({label}:{label:string}){return <div className="emptymsg"><CheckCircle2 size={24}/><span>{label}</span></div>}
function OrderTable({orders,nameOf,paidFor,setStatus}:{orders:Order[];nameOf:(x:string)=>string;paidFor:(x:string)=>number;setStatus:(id:string,s:Order['status'])=>void}){return <div className="tablewrap"><table><thead><tr><th>Дата</th><th>Клиент / программа / место</th><th>Цена</th><th>Оплачено</th><th>Статус</th></tr></thead><tbody>{orders.map(o=><tr key={o.id}><td><span className="strong">{o.date}</span><small>{o.start} · {o.duration} мин</small></td><td><span className="strong">{nameOf(o.clientId)}</span><small>{o.program} · {o.id}</small><small>📍 {o.location||"Место не указано"}</small></td><td>{money(o.price)}</td><td>{money(paidFor(o.id))}</td><td><select className="status" value={o.status} onChange={e=>setStatus(o.id,e.target.value as Order['status'])}>{Object.entries(statLabel).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select></td></tr>)}</tbody></table>{orders.length===0&&<Empty label="Пока нет заказов — создайте первый"/>}</div>}
