/* Call-health measurements are numerical only. No audio samples leave the browser. */
(function (global) {
  'use strict';
  const finite = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
  const metric = (value, scale = 1) => finite(value) ? value * scale : null;
  const delta = (current, previous, key) => finite(current?.[key]) && finite(previous?.[key]) && current[key] >= previous[key] ? current[key] - previous[key] : null;
  const ratio = (n, d, scale = 1) => n !== null && d !== null && d > 0 ? n / d * scale : null;

  function parseStats(reports, previous = new Map()) {
    const values = Array.from(reports.values());
    const incoming = values.find(r => r.type === 'inbound-rtp' && (r.kind || r.mediaType) === 'audio');
    const outgoing = values.find(r => r.type === 'outbound-rtp' && (r.kind || r.mediaType) === 'audio');
    if (!incoming) return { sample: null, previous: new Map(values.map(r => [r.id, r])) };
    const old = previous.get(incoming.id);
    const oldOut = outgoing && previous.get(outgoing.id);
    const elapsed = old && incoming.timestamp - old.timestamp;
    const outElapsed = oldOut && outgoing.timestamp - oldOut.timestamp;
    const validInterval = elapsed > 0 && elapsed <= 20000;
    const lost = validInterval ? delta(incoming, old, 'packetsLost') : null;
    const received = validInterval ? delta(incoming, old, 'packetsReceived') : null;
    const remote = values.find(r => r.type === 'remote-inbound-rtp' && r.localId === outgoing?.id);
    const transport = values.find(r => r.type === 'transport' && (r.id === incoming.transportId || r.id === outgoing?.transportId));
    const pair = values.find(r => r.type === 'candidate-pair' && r.state === 'succeeded' && (r.id === transport?.selectedCandidatePairId || r.nominated));
    const sample = {
      loss: lost === null || received === null ? null : ratio(lost, lost + received, 100),
      jitter: metric(incoming.jitter, 1000),
      rtt: metric(remote?.roundTripTime, 1000) ?? metric(pair?.currentRoundTripTime, 1000),
      concealment: validInterval ? ratio(delta(incoming, old, 'concealedSamples'), delta(incoming, old, 'totalSamplesReceived'), 100) : null,
      buffer: validInterval ? ratio(delta(incoming, old, 'jitterBufferDelay'), delta(incoming, old, 'jitterBufferEmittedCount'), 1000) : null,
      rxBitrate: validInterval ? ratio(delta(incoming, old, 'bytesReceived'), elapsed, 8) : null,
      txBitrate: outElapsed > 0 && outElapsed <= 20000 ? ratio(delta(outgoing, oldOut, 'bytesSent'), outElapsed, 8) : null,
      upstreamLoss: finite(remote?.fractionLost) && remote.fractionLost <= 1 ? remote.fractionLost * 100 : null
    };
    return { sample, previous: new Map(values.map(r => [r.id, r])) };
  }

  const recommendations = {
    healthy: 'No sustained network problem detected.',
    insufficient_data: 'Waiting for enough browser measurements.',
    reduce_screen_bitrate: 'Outgoing packets are being lost. Lower screen quality may help.',
    audio_gaps: 'The browser is replacing missing audio. Check network stability.',
    receiving_packet_loss: 'Incoming audio packets are being lost.',
    high_latency: 'Network delay is high. Avoid busy Wi-Fi or heavy downloads.',
    unstable_arrival: 'Audio packets are arriving unevenly. A steadier connection may help.'
  };
  function create({ getPeers, getRoom, send, getLabel = () => 'Participant', analysisEnabled = true, adaptiveScreen = false, adapt = () => {} }) {
    const states = new Map();
    const pending = new Map();
    let timer = null;
    let generation = 0;
    let seq = 0;
    let epoch = null;
    let unavailableUntil = 0;
    let running = false;
    const format = (value, unit) => finite(value) ? `${value.toFixed(value < 10 ? 1 : 0)}${unit}` : 'Unavailable';

    function render() {
      const mount = document.querySelector('[data-call-health-list]');
      if (!mount) return;
      const fragment = document.createDocumentFragment();
      for (const [uid, state] of states) {
        if (getPeers().get(uid) !== state.pc) continue;
        const card = document.createElement('div'); card.className = 'call-health-peer';
        const heading = document.createElement('div'); heading.className = 'call-health-heading';
        const name = document.createElement('b'); name.textContent = getLabel(uid);
        const status = document.createElement('span');
        const connected = state.pc.connectionState === 'connected';
        const score = state.analysis?.score;
        status.textContent = !connected ? 'Reconnecting' : !finite(score) ? 'Measuring' : score >= 80 ? 'Good' : score >= 55 ? 'Fair' : 'Poor';
        status.className = `call-health-status ${!connected || (finite(score) && score < 55) ? 'poor' : finite(score) && score >= 80 ? 'good' : ''}`;
        heading.append(name, status); card.append(heading);
        const metrics = document.createElement('dl'); metrics.className = 'call-health-metrics';
        const sample = state.sample || {};
        for (const [label, value] of [['Round trip', format(sample.rtt, ' ms')], ['Packet loss', format(sample.loss, '%')], ['Jitter', format(sample.jitter, ' ms')], ['Concealed audio', format(sample.concealment, '%')], ['Buffer delay', format(sample.buffer, ' ms')], ['Receiving', format(sample.rxBitrate, ' kb/s')]]) {
          const dt = document.createElement('dt'); dt.textContent = label;
          const dd = document.createElement('dd'); dd.textContent = value;
          metrics.append(dt, dd);
        }
        card.append(metrics);
        const note = document.createElement('p');
        note.textContent = !connected ? 'Waiting for the call connection to recover.' : state.analysis ? recommendations[state.analysis.recommendation] || recommendations.insufficient_data : 'Live browser measurements. Trend analysis is not available yet.';
        card.append(note); fragment.append(card);
      }
      if (!fragment.childNodes.length) {
        const empty = document.createElement('p'); empty.textContent = 'Measurements appear once audio connects.'; fragment.append(empty);
      }
      mount.replaceChildren(fragment);
    }

    async function collect() {
      if (running) return;
      const room = getRoom();
      if (!room?.joined) { stop(); return; }
      if (epoch !== room.epoch) { states.clear(); pending.clear(); epoch = room.epoch; }
      const currentGeneration = generation;
      running = true;
      try {
        const livePeers = Array.from(getPeers()).slice(0, 8);
        const activeIds = new Set(livePeers.map(([uid]) => uid));
        for (const uid of states.keys()) if (!activeIds.has(uid)) states.delete(uid);
        for (const [uid, pc] of livePeers) {
          if (pc.connectionState === 'closed') continue;
          let state = states.get(uid);
          if (!state || state.pc !== pc) {
            state = { pc, previous: new Map(), rows: [], sample: null, analysis: null, lastSent: 0, poor: 0, good: 0, limited: false };
            states.set(uid, state);
          }
          let reports;
          try { reports = await pc.getStats(); } catch (_) { continue; }
          if (currentGeneration !== generation || getRoom()?.epoch !== epoch || getPeers().get(uid) !== pc) return;
          const parsed = parseStats(reports, state.previous);
          state.previous = parsed.previous;
          state.sample = parsed.sample;
          if (!parsed.sample || pc.connectionState !== 'connected') { state.rows = []; state.analysis = null; continue; }
          const s = parsed.sample;
          const now = performance.now();
          if (state.rows.length && now / 1000 - state.rows.at(-1)[0] > 20) { state.rows = []; state.analysis = null; }
          if (now - (state.analyzedAt || 0) > 20000) state.analysis = null;
          state.rows.push([now / 1000, s.loss, s.jitter, s.rtt, s.concealment, s.buffer, s.rxBitrate, s.txBitrate, s.upstreamLoss]);
          state.rows = state.rows.slice(-12);
          if (analysisEnabled && now >= unavailableUntil && state.rows.length >= 3 && now - state.lastSent >= 10000) {
            const request = `${epoch}:${uid}:${++seq}`;
            const startTime = state.rows[0][0];
            const rows = state.rows.map(row => row.map((value, i) => i === 0 ? value - startTime : finite(value) ? value : -1));
            pending.set(request, { uid, pc, epoch, at: now });
            state.lastSent = now;
            send({ type: 'call_quality', request_id: request, peer_id: uid, samples: rows });
          }
        }
        for (const [id, request] of pending) if (performance.now() - request.at > 15000) pending.delete(id);
        render();
      } finally { running = false; }
    }

    function receive(message) {
      const request = pending.get(message.request_id);
      pending.delete(message.request_id);
      if (!request || request.epoch !== getRoom()?.epoch || getPeers().get(request.uid) !== request.pc) return;
      const state = states.get(request.uid);
      if (!state || state.pc !== request.pc) return;
      if (message.result?.unavailable) { unavailableUntil = performance.now() + 60000; state.analysis = null; render(); return; }
      const result = message.result;
      if (!result || !Object.hasOwn(recommendations, result.recommendation)) return;
      state.analysis = result;
      state.analyzedAt = performance.now();
      if (adaptiveScreen) {
        state.poor = result.recommendation === 'reduce_screen_bitrate' ? state.poor + 1 : 0;
        state.good = result.recommendation === 'healthy' && result.score >= 85 ? state.good + 1 : 0;
        if (!state.limited && state.poor >= 3) { state.limited = true; adapt(request.pc, true); }
        if (state.limited && state.good >= 6) { state.limited = false; adapt(request.pc, false); }
      }
      render();
    }
    function start() {
      if (timer) return;
      timer = setInterval(() => collect().catch(() => {}), 5000);
      collect().catch(() => {});
    }
    function stop() {
      generation++;
      clearInterval(timer); timer = null;
      states.clear(); pending.clear(); epoch = null;
    }
    // Reopening a panel renders the most recent sample without another stats poll.
    document.addEventListener('toggle', event => { if (event.target.matches?.('.call-health') && event.target.open) render(); }, true);
    return { start, stop, receive };
  }
  global.PlainwireCallHealth = Object.freeze({ parseStats, create });
})(globalThis);
