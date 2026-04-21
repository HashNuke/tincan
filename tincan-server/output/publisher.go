package output

type Listener interface {
	HandleEvent(event Event) error
}

type Publisher struct {
	listeners []Listener
}

func NewPublisher(listeners ...Listener) *Publisher {
	return &Publisher{listeners: listeners}
}

func (p *Publisher) AddListener(listener Listener) {
	p.listeners = append(p.listeners, listener)
}

func (p *Publisher) Publish(events ...Event) error {
	for _, event := range events {
		for _, listener := range p.listeners {
			if err := listener.HandleEvent(event); err != nil {
				return err
			}
		}
	}
	return nil
}
