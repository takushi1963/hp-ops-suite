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
function render(d) {
  const problems = critical(d);
  $('updated').textContent = `Host: ${display(d.host)} / データ生成: ${new Date(d.generated_at).toLocaleString()} / 取得: ${new Date().toLocaleString()}`;
  const list = text('ul','');
  if (problems.length) for (const issue of problems) list.append(text('li',issue,'warn'));
  else list.append(text('li','確認対象は正常です','ok'));
  $('critical').replaceChildren(list);
  const receiverState = d.receiver ? d.services[d.receiver] : 'unknown';
  const temperature = Number(d.system.cpu_temp), disk = Number(d.system.disk_pct);
  $('health').replaceChildren(
    card('ADS-B受信',receiverState,receiverState,d.receiver),
    card('航空機',d.aircraft.count,d.aircraft.state,'データ時刻: '+display(d.aircraft.updated_at)),
    card('録音',d.services['ops-audio-ring.service'],d.services['ops-audio-ring.service']),
    card('CPU温度',d.system.cpu_temp === null ? '未取得' : display(d.system.cpu_temp)+' °C', d.system.cpu_temp === null ? 'unknown' : temperature>=75?'error':temperature>=60?'warn':'ok'),
    card('Disk /',d.system.disk_pct === null ? '未取得' : display(d.system.disk_pct)+' %',d.system.disk_pct === null?'unknown':disk>=85?'error':disk>=70?'warn':'ok'),
    card('失敗サービス',d.system.failed_units,d.system.failed_units===null?'unknown':Number(d.system.failed_units)===0?'ok':'error')
  );
  const feedRows = d.feeds.map(feed => {
    const row = text('tr','');
    row.append(text('td',feed.name),text('td',feed.state,tone(feed.state)),
      text('td',feed.reason ?? feed.network),text('td',feed.checked_at ?? feed.timestamp));
    return row;
  });
  $('feeds').replaceChildren(...feedRows);
  $('audio').textContent = `24時間イベント: ${display(d.events.boom_24h)} / 最新RMS: ${display(d.rms.latest_db)} dB / ${display(d.rms.latest_at)} / 状態: ${d.rms.state}`;
  $('events').replaceChildren(...d.events.rows.map(event=>{
    const row = text('tr',''), playback = text('td','録音未確認');
    const url = safeAudio(event.url);
    if (url) {
      const a = text('a','再生／ダウンロード'); a.href = url;
      playback.replaceChildren(a);
    }
    row.append(text('td',event.ts_utc),text('td',event.source),playback); return row;
  }));
  if (!d.events.rows.length) $('events').append(messageRow(d.events.available ? 'イベントなし' : 'イベント取得不能',3));
  drawRms(d.rms.series);
  $('backup-mount').textContent = '保存先マウント: '+(d.backup.mounted ? '確認済み' : '未確認');
  $('backup-mount').className = d.backup.mounted ? 'ok' : 'ng';
  $('backups').replaceChildren(...d.backup.jobs.map(job=>card(job.name,job.state,job.state,
    '実行時刻: '+display(job.last_run)+' / '+display(job.file)+' / '+display(job.message))));
  $('lowfreq').textContent = JSON.stringify(d.lowfreq,null,2);
  $('fingerprint').textContent = '音紋学習: '+display(d.fingerprint.status)+' / '+display(d.fingerprint.reason);
}
let busy = false;
let nextTimer = null;
async function refresh() {
  if (busy) return;
  busy = true; clearTimeout(nextTimer); $('refresh').disabled = true;
  const controller = new AbortController();
  const timeout = setTimeout(()=>controller.abort(),8000);
  try {
    const response = await fetch('/status/dashboard.json',{cache:'no-store',signal:controller.signal});
    if (!response.ok) throw new Error('HTTP '+response.status);
    render(validate(await response.json()));
  } catch (error) {
    $('critical').replaceChildren(text('p','取得失敗: '+error.message,'ng'));
    $('updated').textContent = '更新失敗。残っている値は前回の取得結果です。';
    for (const id of ['health','backups']) $(id).replaceChildren(text('p','現在値を取得できません','warn'));
    $('feeds').replaceChildren(messageRow('現在値を取得できません',4));
    $('events').replaceChildren(messageRow('現在値を取得できません',3));
    $('audio').textContent = '音声データを取得できません';
    $('rms-chart').replaceChildren(); $('rms-range').textContent = '';
    $('backup-mount').textContent = '保存先マウント: 未取得'; $('backup-mount').className='warn';
    $('lowfreq').textContent='低周波集計: 未取得'; $('fingerprint').textContent='音紋学習: 未取得';
  } finally {
    clearTimeout(timeout); busy = false; $('refresh').disabled = false;
    nextTimer = setTimeout(refresh,10000);
  }
}
$('refresh').addEventListener('click',refresh);
refresh();
