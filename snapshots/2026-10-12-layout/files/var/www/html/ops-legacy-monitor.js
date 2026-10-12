'use strict';
const $ = id => document.getElementById(id);
const display = value => value === null || value === undefined ? '未取得' : String(value);
function tone(state) {
  return ['active','OK','ok','done','ESTABLISHED'].includes(state) ? 'ok' :
    ['failed','error','NG','inactive'].includes(state) ? 'ng' : 'warn';
}
function text(tag, value, cls) {
  const el = document.createElement(tag);
  el.textContent = display(value);
  if (cls) el.className = cls;
  return el;
}
function messageRow(message, columns) {
  const row = text('tr',''), cell = text('td',message,'warn');
  cell.colSpan = columns; row.append(cell); return row;
}
function card(title, value, state, detail) {
  const el = text('div', '', 'card');
  el.append(text('strong', title), text('span', value, 'large '+tone(state)));
  if (detail) el.append(text('small', detail, 'muted'));
  return el;
}
function safeAudio(value) {
  if (typeof value !== 'string' || !/^\/audio-events\/(auto|button)\/[^/]+\.wav$/.test(value)) return null;
  try {
    const u = new URL(value, window.location.origin);
    const leaf = decodeURIComponent(u.pathname.split('/').pop());
    if (u.origin !== window.location.origin || /[\\/\x00-\x1f]/.test(leaf)) return null;
    return u.pathname;
  } catch (_) { return null; }
}
function validate(d) {
  if (!d || d.version !== 1 || typeof d.generated_at !== 'string' ||
      !Number.isFinite(Date.parse(d.generated_at)) || !d.system || !d.services ||
      !d.aircraft || !d.events || !d.rms || !d.backup || !d.lowfreq || !d.fingerprint ||
      !Array.isArray(d.feeds) || !Array.isArray(d.events.rows) ||
      !Array.isArray(d.backup.jobs) || !Array.isArray(d.errors) || !Array.isArray(d.rms.series)) {
    throw new Error('監視データの形式が不正です');
  }
  return d;
}
function critical(d) {
  const issues = [...d.errors];
  if (d.system.cpu_temp !== null && Number(d.system.cpu_temp) >= 75) issues.push('CPU温度が高い状態です');
  if (d.system.disk_pct !== null && Number(d.system.disk_pct) >= 85) issues.push('ルートディスクの空き容量を確認してください');
  if (d.lowfreq.state !== 'ok') issues.push('低周波集計の元データ: '+d.lowfreq.state);
  const age = (Date.now() - Date.parse(d.generated_at)) / 1000;
  if (age > 120 || age < -300) issues.push('監視データの生成時刻が期限外です');
  if (d.system.failed_units === null) issues.push('失敗サービス数を取得できません');
  else if (Number(d.system.failed_units) > 0) issues.push('失敗サービス: '+d.system.failed_units);
  if (!d.receiver || d.services[d.receiver] !== 'active') issues.push('ADS-B受信サービスを確認してください');
  if (d.aircraft.state !== 'ok') issues.push('航空機データ: '+d.aircraft.state);
  if (d.services['ops-audio-ring.service'] !== 'active') issues.push('録音サービスを確認してください');
  if (d.rms.state !== 'ok') issues.push('RMSデータ: '+d.rms.state);
  for (const feed of d.feeds) {
    if (!['active','OK'].includes(feed.state)) issues.push(feed.name+': '+feed.state);
  }
  for (const job of d.backup.jobs) {
    if (!['done','running'].includes(job.state)) issues.push('バックアップ '+job.name+': '+job.state);
  }
  return [...new Set(issues)];
}
function drawRms(series) {
  const chart = $('rms-chart'); chart.replaceChildren();
  const points = series.map(p => [Date.parse(p[0]), Number(p[1])])
    .filter(p => p.every(Number.isFinite));
  if (!points.length) { $('rms-range').textContent = 'RMSサンプルがありません'; return; }
  const begin = Math.min(...points.map(p=>p[0])), end = Math.max(...points.map(p=>p[0]));
  const values = points.map(p=>p[1]);
  const low = Math.min(...values)-2, high = Math.max(...values)+2;
  const line = document.createElementNS('http://www.w3.org/2000/svg','polyline');
  line.setAttribute('points', points.map(([t,v])=>`${10+980*(t-begin)/Math.max(1,end-begin)},${170-160*(v-low)/(high-low)}`).join(' '));
  line.setAttribute('fill','none'); line.setAttribute('stroke','#9ed7ff'); line.setAttribute('stroke-width','2');
  chart.append(line);
  $('rms-range').textContent = `RMS ${low.toFixed(1)}〜${high.toFixed(1)} dB / ${new Date(begin).toLocaleString()}〜${new Date(end).toLocaleString()}`;
}
function summary(id,value,state) {
  $(id).textContent=display(value);
  $(id).className='health-value health-'+(tone(state)==='ng'?'ng':tone(state)==='ok'?'ok':'warn');
}
function render(d) {
  const problems=critical(d);
  $('updated').textContent='Host: '+display(d.host)+' / データ生成: '+new Date(d.generated_at).toLocaleString();
  $('critical').textContent=problems.length?problems.join('\n'):'確認対象は正常です';
  $('critical').className=problems.length?'warn':'ok';
  $('feedTable').replaceChildren(...d.feeds.map(feed=>{
    const row=text('tr','');
    row.append(text('td',feed.name),text('td',feed.service),text('td',feed.state,tone(feed.state)),text('td',feed.reason??feed.network),text('td',feed.checked_at??feed.timestamp),text('td','—'));
    return row;
  }));
  if (!d.feeds.length) $('feedTable').append(messageRow('配信データなし',6));
  const audio=d.services['ops-audio-ring.service'];
  const receiver=d.receiver?d.services[d.receiver]:'unknown';
  summary('sumAudio',audio,audio);summary('sumAdsb',receiver,receiver);
  summary('sumAircraft',d.aircraft.count,d.aircraft.state);
  summary('sumTemp',d.system.cpu_temp==null?'未取得':d.system.cpu_temp+' °C',d.system.cpu_temp==null?'unknown':d.system.cpu_temp>=75?'error':d.system.cpu_temp>=60?'warn':'ok');
  summary('sumDisk',d.system.disk_pct==null?'未取得':d.system.disk_pct+' %',d.system.disk_pct==null?'unknown':d.system.disk_pct>=85?'error':d.system.disk_pct>=70?'warn':'ok');
  const dd=d.backup.jobs.find(j=>j.name==='dd');
  summary('sumDd',dd?dd.state+' / '+display(dd.last_run):'未取得',dd?.state??'unknown');
  $('opsHealth').textContent=JSON.stringify({generated_at:d.generated_at,system:d.system,receiver:d.receiver,aircraft:d.aircraft,services:d.services},null,2);
  $('fpSummary').textContent='Status: '+display(d.fingerprint.status)+'\n'+display(d.fingerprint.reason);
  $('boom24h').textContent=display(d.events.boom_24h);
  $('events').replaceChildren(...d.events.rows.map(event=>{
    const row=text('tr',''),play=text('td','録音未確認'),url=safeAudio(event.url);
    if(url){const link=text('a','再生／ダウンロード');link.href=url;play.replaceChildren(link);}
    row.append(text('td',event.ts_utc),text('td',event.source),play);return row;
  }));
  if(!d.events.rows.length)$('events').append(messageRow(d.events.available?'イベントなし':'イベント取得不能',3));
  drawRms(d.rms.series);
  $('audioStatus').textContent='RMS: '+display(d.rms.latest_db)+' dB\n更新: '+display(d.rms.latest_at)+'\n状態: '+display(d.rms.state);
  $('backupStatus').textContent='保存先マウント: '+(d.backup.mounted?'確認済み':'未確認')+'\n'+d.backup.jobs.map(j=>j.name+': '+j.state+'\n実行時刻: '+display(j.last_run)+'\n'+display(j.message)).join('\n\n');
  $('opsSummary').textContent='低周波集計\n'+JSON.stringify(d.lowfreq,null,2)+'\n\n収集エラー\n'+(d.errors.length?d.errors.join('\n'):'なし');
}
let busy=false,nextTimer=null;
async function refresh(){
  if(busy)return;
  busy=true;clearTimeout(nextTimer);
  const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),8000);
  try{
    const response=await fetch('/status/dashboard.json',{cache:'no-store',signal:controller.signal});
    if(!response.ok)throw new Error('HTTP '+response.status);
    render(validate(await response.json()));
  }catch(error){
    $('updated').textContent='更新失敗。現在値を取得できません。';
    $('critical').textContent='取得失敗: '+error.message;$('critical').className='ng';
    for(const id of ['sumAudio','sumAdsb','sumAircraft','sumTemp','sumDisk','sumDd'])summary(id,'未取得','unknown');
    for(const id of ['opsHealth','fpSummary','audioStatus','backupStatus','opsSummary'])$(id).textContent='現在値を取得できません';
    $('boom24h').textContent='未取得';
    $('feedTable').replaceChildren(messageRow('現在値を取得できません',6));
    $('events').replaceChildren(messageRow('現在値を取得できません',3));
    $('rms-chart').replaceChildren();$('rms-range').textContent='';
  }finally{clearTimeout(timeout);busy=false;nextTimer=setTimeout(refresh,10000);}
}
const grafana=$('grafana-link');
if(grafana){const url=new URL(window.location.origin);url.port='3000';grafana.href=url.href;}
refresh();
