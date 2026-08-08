package main

import "sync"

// hub fans traffic out from a Roblox job server to every websocket client
// watching that job. A single channel shared by all clients would hand each
// message to exactly one of them, so subscribers get their own buffered
// channel instead.
type hub struct {
	mu   sync.Mutex
	subs map[string]map[chan []byte]struct{}
}

func newHub() *hub {
	return &hub{subs: make(map[string]map[chan []byte]struct{})}
}

// subscribe registers a new client for jobID. The caller must unsubscribe when
// it is done; that is what closes the returned channel.
func (h *hub) subscribe(jobID string) chan []byte {
	ch := make(chan []byte, subscriberBuffer)

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[jobID] == nil {
		h.subs[jobID] = make(map[chan []byte]struct{})
	}
	h.subs[jobID][ch] = struct{}{}
	return ch
}

// unsubscribe removes a client and closes its channel, which ends the writer
// goroutine ranging over it. Safe to call more than once.
func (h *hub) unsubscribe(jobID string, ch chan []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()

	subs := h.subs[jobID]
	if _, ok := subs[ch]; !ok {
		return
	}
	delete(subs, ch)
	if len(subs) == 0 {
		delete(h.subs, jobID)
	}
	close(ch)
}

// publish delivers msg to every client watching jobID and reports how many
// received it. It never blocks: a client whose buffer is full loses the
// message rather than stalling the /incoming request that produced it.
func (h *hub) publish(jobID string, msg []byte) (delivered, dropped int) {
	h.mu.Lock()
	defer h.mu.Unlock()

	for ch := range h.subs[jobID] {
		select {
		case ch <- msg:
			delivered++
		default:
			dropped++
		}
	}
	return delivered, dropped
}
