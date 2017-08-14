from __future__ import absolute_import, division, print_function, unicode_literals

import time

import mock
from pytest import raises

from gratipay.exceptions import Throttled
from gratipay.testing import Harness
from gratipay.testing.email import SentEmailHarness, QueuedEmailHarness


class TestPut(QueuedEmailHarness):

    def setUp(self):
        QueuedEmailHarness.setUp(self)
        self.alice = self.make_participant('alice', claimed_time='now', email_address='alice@example.com')

    def test_put_with_only_email(self):
        self.app.email_queue.put(None, 'base', email='dummy@example.com')
        last_email = self.get_last_email()
        assert last_email['to'] == 'dummy@example.com'

    def test_put_with_only_participant(self):
        self.app.email_queue.put(self.alice, 'base')

        # Should pickup primary email
        assert self.get_last_email()['to'] == 'alice <alice@example.com>'

    def test_put_with_participant_and_email(self):
        self.app.email_queue.put(self.alice, 'base', email='alice2@example.com')

        # Should prefer given email over primary
        assert self.get_last_email()['to'] == 'alice <alice2@example.com>'

    def test_put_complains_if_participant_and_email_not_provided(self):
        with raises(AssertionError):
            self.app.email_queue.put(None, "base")

    def test_put_throttles_on_participant(self):
        self.app.email_queue.put(self.alice, "base")
        self.app.email_queue.put(self.alice, "base")
        self.app.email_queue.put(self.alice, "base")
        raises(Throttled, self.app.email_queue.put, self.alice, "base")

    def test_put_throttles_on_email(self):
        self.app.email_queue.put(None, "base", email="alice@gratipay.com")
        self.app.email_queue.put(None, "base", email="alice@gratipay.com")
        self.app.email_queue.put(None, "base", email="alice@gratipay.com")
        with raises(Throttled):
            self.app.email_queue.put(None, "base", email="alice@gratipay.com")

    def test_put_throttles_on_participant_across_different_emails(self):
        self.app.email_queue.put(self.alice, "base", email="a@b.com")
        self.app.email_queue.put(self.alice, "base", email="b@c.com")
        self.app.email_queue.put(self.alice, "base", email="c@d.com")
        with raises(Throttled):
            self.app.email_queue.put(self.alice, "base", email="d@e.com")

    def test_timestamp_is_written(self):
        self.app.email_queue.put(self.alice, "base")

        ctime = self.db.one("SELECT EXTRACT(epoch FROM ctime) FROM email_queue")
        assert abs(ctime - time.time()) < 300

    def test_only_user_initiated_messages_count_towards_throttling(self):
        self.app.email_queue.put(self.alice, "base")
        self.app.email_queue.put(self.alice, "base", _user_initiated=False)
        self.app.email_queue.put(self.alice, "base")
        self.app.email_queue.put(self.alice, "base", _user_initiated=False)
        self.app.email_queue.put(self.alice, "base")
        self.app.email_queue.put(self.alice, "base", _user_initiated=False)
        raises(Throttled, self.app.email_queue.put, self.alice, "branch")

    def test_flushing_queue_resets_throttling(self):
        self.app.email_queue.put(self.alice, "base")
        self.app.email_queue.put(self.alice, "base")
        self.app.email_queue.put(self.alice, "base")
        assert self.app.email_queue.flush() == 3
        self.app.email_queue.put(self.alice, "base")


class TestFlush(SentEmailHarness):

    def put_message(self, email_address='larry@example.com'):
        larry = self.make_participant('larry', email_address=email_address)
        self.app.email_queue.put(larry, "base")

    def test_can_flush_an_email_from_the_queue(self):
        self.put_message()

        assert self.db.one("SELECT spt_name FROM email_queue") == "base"
        self.app.email_queue.flush()
        assert self.count_email_messages() == 1
        last_email = self.get_last_email()
        assert last_email['to'] == 'larry <larry@example.com>'
        expected = "Something not right?"
        assert expected in last_email['body_text']
        assert self.db.one("SELECT spt_name FROM email_queue") is None

    def test_flushing_an_email_without_address_just_skips_it(self):
        self.put_message(email_address=None)

        assert self.db.one("SELECT spt_name FROM email_queue") == "base"
        self.app.email_queue.flush()
        assert self.count_email_messages() == 0
        assert self.db.one("SELECT spt_name FROM email_queue") is None

    def test_flush_does_not_resend_dead_letters(self):
        self.put_message()
        self.db.run("UPDATE email_queue SET dead=true")
        self.app.email_queue.flush()
        assert self.count_email_messages() == 0

    def test_failed_flushes_are_marked_as_dead_letters(self):
        # patch mailer
        class SomeProblem(Exception): pass
        def failer(*a, **kw): raise SomeProblem()
        self.app.email_queue._mailer.send_email = failer

        # queue a message
        self.put_message()
        assert not self.db.one("SELECT dead FROM email_queue")

        # now try to send it
        raises(SomeProblem, self.app.email_queue.flush)
        assert self.count_email_messages() == 0  # nothing sent
        assert self.db.one("SELECT dead FROM email_queue")

class TestLogMetrics(Harness):

    def test_log_metrics(self):
        alice = self.make_participant('alice', claimed_time='now', email_address='alice@example.com')

        self.app.email_queue.put(alice, "base")
        self.app.email_queue.put(alice, "base")
        self.app.email_queue.put(alice, "base")

        self.db.run("UPDATE email_queue SET dead = 'true' WHERE id IN (SELECT id FROM email_queue LIMIT 1)")

        mock_print = mock.Mock()

        self.app.email_queue.log_metrics(_print=mock_print)
        mock_print.assert_called_once_with('count#email_queue_dead=1 count#email_queue_total=3')
