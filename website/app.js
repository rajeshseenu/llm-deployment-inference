async function send() {
  const input = document.getElementById('prompt');
  const chat = document.getElementById('chat');
  const text = input.value.trim();
  if (!text) return;

  chat.innerHTML += `<div class="msg user"><b>You:</b> ${text}</div>`;
  input.value = '';

  try {
    const res = await fetch('/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: '/model',
        messages: [{ role: 'user', content: text }],
        max_tokens: 150
      })
    });
    const data = await res.json();
    const reply = data.choices?.[0]?.message?.content || JSON.stringify(data);
    chat.innerHTML += `<div class="msg bot"><b>LLM:</b> ${reply}</div>`;
  } catch (err) {
    chat.innerHTML += `<div class="msg bot"><b>Error:</b> ${err}</div>`;
  }
  chat.scrollTop = chat.scrollHeight;
}

document.getElementById('prompt').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') send();
});
