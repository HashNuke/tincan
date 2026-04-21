package output

type Kind string

const (
	KindImmediateFeedback     Kind = "immediate_feedback"
	KindClarificationQuestion Kind = "clarification_question"
	KindUpdateSummary         Kind = "update_summary"
	KindContextSwitch         Kind = "context_switch"
	KindNotification          Kind = "notification"
)

type Event struct {
	SessionID   string `json:"session_id"`
	Kind        Kind   `json:"kind"`
	Text        string `json:"text"`
	SummaryText string `json:"summary_text,omitempty"`
}
