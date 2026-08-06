const modes = {
  listen: { label: '倾听模式', prompt: '我在。你可以从任何一处开始。', sub: '按住说话，或轻点开始一段不被催促的讲述。', end: '谢谢你把这些交给我。现在想让我替你留下一点什么吗？' },
  diary: { label: '日记模式', prompt: '今天发生了什么？慢慢说。', sub: '我会在结束时替你整理；是否留下，全由你决定。', end: '我先把今天轻轻收起来。你愿意留下这一页吗？' }
};
let currentMode = 'listen', recording = false, mediaStream, analyser, frame, startedAt;
const $ = (s) => document.querySelector(s);
const record = $('#recordButton'), orb = $('#orbWrap'), status = $('#status');

document.querySelectorAll('.mode').forEach((button) => button.addEventListener('click', () => {
  if (recording) return;
  currentMode = button.dataset.mode;
  document.querySelectorAll('.mode').forEach((item) => item.classList.toggle('active', item === button));
  const mode = modes[currentMode];
  $('#modeLabel').textContent = mode.label; $('#prompt').textContent = mode.prompt; $('#subprompt').textContent = mode.sub;
}));

async function start() {
  try {
    mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const audio = new AudioContext(), source = audio.createMediaStreamSource(mediaStream);
    analyser = audio.createAnalyser(); analyser.fftSize = 256; source.connect(analyser);
    recording = true; startedAt = Date.now();
    record.classList.add('recording'); orb.classList.add('listening'); status.textContent = '正在听';
    $('#recordText').textContent = '结束这一段'; $('#subprompt').textContent = '我在听。停顿也没关系。';
    renderLevel();
    await fetch('/api/session', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ mode: currentMode }) });
  } catch {
    status.textContent = '需要麦克风权限'; $('#subprompt').textContent = '允许麦克风后，TARST 才能陪你说话。';
  }
}
function renderLevel() {
  const values = new Uint8Array(analyser.frequencyBinCount); analyser.getByteFrequencyData(values);
  const level = values.reduce((sum, value) => sum + value, 0) / values.length / 255;
  orb.style.setProperty('--voice', Math.max(.08, level * 1.65));
  frame = requestAnimationFrame(renderLevel);
}
function stop() {
  recording = false; cancelAnimationFrame(frame); mediaStream?.getTracks().forEach((track) => track.stop());
  record.classList.remove('recording'); orb.classList.remove('listening'); orb.style.setProperty('--voice', 0);
  status.textContent = '这一段结束了'; $('#recordText').textContent = '再说一点';
  $('#prompt').textContent = modes[currentMode].end; $('#subprompt').textContent = '不用急着回答。';
  const minutes = Math.max(1, Math.round((Date.now() - startedAt) / 60000));
  $('#noteText').innerHTML = `<p><strong>今天的片段</strong></p><p>你留出了一段 ${minutes} 分钟的时间，慢慢把心里的事说出来。</p><p>这不是结论，也不是评价。它只是今天曾经真实存在过的一点痕迹。</p>`;
  setTimeout(() => $('#reflection').classList.remove('hidden'), 700);
}
record.addEventListener('click', () => recording ? stop() : start());
$('#saveNote').addEventListener('click', () => { $('#saveNote').textContent = '已经留下'; $('#saveNote').disabled = true; });
$('#editNote').addEventListener('click', () => { $('#noteText').contentEditable = 'true'; $('#noteText').focus(); });
$('#closeReflection').addEventListener('click', () => $('#reflection').classList.add('hidden'));
$('#historyButton').addEventListener('click', () => $('#historyDialog').showModal());
$('#closeHistory').addEventListener('click', () => $('#historyDialog').close());
