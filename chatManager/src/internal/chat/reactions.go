package chat

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

// Reactions, and editing a message's text.
//
// A reaction is stored as its own row rather than folded into the message it is
// on, because the two arrive and change separately: a reaction can turn up
// before its message (history paging walks backwards), a message is rewritten
// whole by every redelivery and edit, and a reaction taken back is named by the
// reaction's own id, not by the message.

// PutReactions stores reactions in one transaction, replacing what was known
// of any it already had -- the copy echoed back after we reacted carries the
// sender's name, which the one recorded at once did not.
func (s *HistoryStore) PutReactions(ctx context.Context, reactions []Reaction) error {
	if len(reactions) == 0 {
		return nil
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for _, r := range reactions {
		if r.ID == "" || r.ChatID == "" || r.MessageID == "" || r.Key == "" {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
INSERT INTO reactions (provider, chat_id, id, message_id, key, sender_id, sender_name, from_me, ts)
VALUES (?,?,?,?,?,?,?,?,?)
ON CONFLICT(provider, chat_id, id) DO UPDATE SET
  message_id  = excluded.message_id,
  key         = excluded.key,
  sender_id   = CASE WHEN excluded.sender_id   != '' THEN excluded.sender_id   ELSE reactions.sender_id   END,
  sender_name = CASE WHEN excluded.sender_name != '' THEN excluded.sender_name ELSE reactions.sender_name END,
  from_me     = excluded.from_me OR reactions.from_me,
  ts          = CASE WHEN excluded.ts > 0 THEN excluded.ts ELSE reactions.ts END`,
			r.Provider, r.ChatID, r.ID, r.MessageID, r.Key, r.SenderID, r.SenderName, r.FromMe, r.TS); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// DeleteReaction removes one reaction by its own id. Removing one that is not
// there is not an error: a deletion names a message as often as a reaction,
// and the caller cannot tell which.
func (s *HistoryStore) DeleteReaction(ctx context.Context, provider, chatID, id string) error {
	_, err := s.db.ExecContext(ctx,
		`DELETE FROM reactions WHERE provider = ? AND chat_id = ? AND id = ?`, provider, chatID, id)
	return err
}

// MyReaction finds the reaction we put on a message with a key, returning its
// id or "" when we have none -- which is what taking a reaction back needs,
// since a service removes a reaction by its own id.
func (s *HistoryStore) MyReaction(ctx context.Context, provider, chatID, messageID, key string) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `
SELECT id FROM reactions
 WHERE provider = ? AND chat_id = ? AND message_id = ? AND key = ? AND from_me = 1
 ORDER BY ts DESC LIMIT 1`, provider, chatID, messageID, key).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// attachReactions fills in each message's reactions, one summary per key in
// the order the keys were first used.
//
// One query for the whole page rather than one per message: a refresh asks for
// hundreds of messages at a time.
func (s *HistoryStore) attachReactions(ctx context.Context, provider, chatID string, msgs []Message) error {
	if len(msgs) == 0 {
		return nil
	}

	at := make(map[string]int, len(msgs))
	args := make([]any, 0, len(msgs)+2)
	args = append(args, provider, chatID)
	for i, m := range msgs {
		at[m.ID] = i
		args = append(args, m.ID)
	}

	rows, err := s.db.QueryContext(ctx, `
SELECT message_id, key, sender_name, sender_id, from_me
  FROM reactions
 WHERE provider = ? AND chat_id = ? AND message_id IN (?`+strings.Repeat(",?", len(msgs)-1)+`)
 ORDER BY ts, id`, args...)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var messageID, key, name, sender string
		var mine bool
		if err := rows.Scan(&messageID, &key, &name, &sender, &mine); err != nil {
			return err
		}
		i, ok := at[messageID]
		if !ok {
			continue
		}

		summaries := msgs[i].Reactions
		found := -1
		for j := range summaries {
			if summaries[j].Key == key {
				found = j
				break
			}
		}
		if found < 0 {
			summaries = append(summaries, ReactionSummary{Key: key})
			found = len(summaries) - 1
		}

		summary := &summaries[found]
		summary.Count++
		if mine {
			summary.Mine = true
		}
		// Who, for the tooltip. Ours is said by the shell, which knows how to
		// say "you" in the user's language; the rest by name, or by id when
		// the provider sent none.
		if !mine {
			if name == "" {
				name = sender
			}
			if name != "" {
				summary.Senders = append(summary.Senders, name)
			}
		}
		msgs[i].Reactions = summaries
	}
	return rows.Err()
}

// EditMessage replaces a message's text with an edit we made ourselves, before
// the provider echoes it back.
//
// The formatted copy is cleared rather than kept: it is the old text's, and the
// echo brings the new one.
//
// The edit is marked by moving edited_ts on by one rather than to this
// computer's clock. Versions of a message are ordered by when the service says
// they were made, and a clock running ahead of the service's would make this
// edit look newer than a later one made on the phone -- which would then be
// thrown away as stale. One past whatever the store had is newer than every
// copy it has seen, and older than any edit the service will report after it.
func (s *HistoryStore) EditMessage(ctx context.Context, provider, chatID, id, text string) error {
	res, err := s.db.ExecContext(ctx, `
UPDATE messages SET text = ?, body_html = '', edited_ts = edited_ts + 1
 WHERE provider = ? AND chat_id = ? AND id = ?`, text, provider, chatID, id)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err == nil && n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// ---------------------------------------------------------------- multistore

// PutReactions stores reactions in the store of the provider each belongs to.
func (m *MultiStore) PutReactions(ctx context.Context, reactions []Reaction) error {
	byProvider := map[string][]Reaction{}
	for _, r := range reactions {
		byProvider[r.Provider] = append(byProvider[r.Provider], r)
	}
	for provider, batch := range byProvider {
		s, err := m.For(provider)
		if err != nil {
			return err
		}
		if err := s.PutReactions(ctx, batch); err != nil {
			return err
		}
	}
	return nil
}

func (m *MultiStore) DeleteReaction(ctx context.Context, provider, chatID, id string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.DeleteReaction(ctx, provider, chatID, id)
}

func (m *MultiStore) MyReaction(ctx context.Context, provider, chatID, messageID, key string) (string, error) {
	s, err := m.For(provider)
	if err != nil {
		return "", err
	}
	return s.MyReaction(ctx, provider, chatID, messageID, key)
}

func (m *MultiStore) EditMessage(ctx context.Context, provider, chatID, id, text string) error {
	s, err := m.For(provider)
	if err != nil {
		return err
	}
	return s.EditMessage(ctx, provider, chatID, id, text)
}
