import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/markdown_tasks.dart';

void main() {
  test('counts and toggles -, *, + and numbered items', () {
    const md = '- [ ] a\n* [x] b\n+ [ ] c\n1. [ ] d\n2) [X] e\n- plain\n';
    expect(countTasks(md), 5);
    expect(
      toggleTask(md, 0),
      '- [x] a\n* [x] b\n+ [ ] c\n1. [ ] d\n2) [X] e\n- plain\n',
    );
    expect(
      toggleTask(md, 1),
      '- [ ] a\n* [ ] b\n+ [ ] c\n1. [ ] d\n2) [X] e\n- plain\n',
    );
    expect(
      toggleTask(md, 3),
      '- [ ] a\n* [x] b\n+ [ ] c\n1. [x] d\n2) [X] e\n- plain\n',
    );
  });

  test('[X] counts as checked', () {
    expect(toggleTask('- [X] done', 0), '- [ ] done');
  });

  test('nested and indented items', () {
    const md = '- [ ] parent\n  - [ ] child\n    - [x] grandchild\n';
    expect(countTasks(md), 3);
    expect(
      toggleTask(md, 1),
      '- [ ] parent\n  - [x] child\n    - [x] grandchild\n',
    );
    expect(
      toggleTask(md, 2),
      '- [ ] parent\n  - [ ] child\n    - [ ] grandchild\n',
    );
  });

  test('skips fenced code blocks', () {
    const md = '```\n- [ ] code\n```\n~~~md\n- [ ] tilde\n~~~\n- [ ] real\n';
    expect(countTasks(md), 1);
    expect(
      toggleTask(md, 0),
      '```\n- [ ] code\n```\n~~~md\n- [ ] tilde\n~~~\n- [x] real\n',
    );
  });

  test('a ``` line inside a ~~~ fence does not close it', () {
    const md = '~~~\n```\n- [ ] code\n~~~\n- [ ] real';
    expect(countTasks(md), 1);
    expect(toggleTask(md, 0), '~~~\n```\n- [ ] code\n~~~\n- [x] real');
  });

  test('block quotes', () {
    const md = '> - [ ] quoted\n> > * [x] deeper\n';
    expect(countTasks(md), 2);
    expect(toggleTask(md, 0), '> - [x] quoted\n> > * [x] deeper\n');
    expect(toggleTask(md, 1), '> - [ ] quoted\n> > * [ ] deeper\n');
  });

  test('keeps CRLF line endings and trailing text', () {
    const md = 'Intro\r\n- [ ] a  trailing [ ] text\r\n- [x] b\r\n';
    expect(
      toggleTask(md, 0),
      'Intro\r\n- [x] a  trailing [ ] text\r\n- [x] b\r\n',
    );
    expect(
      toggleTask(md, 1),
      'Intro\r\n- [ ] a  trailing [ ] text\r\n- [ ] b\r\n',
    );
  });

  test('needs a space after ] and a list marker', () {
    expect(countTasks('- [ ]x\n[ ] no marker\n-[ ] no space'), 0);
  });

  test('an index out of range returns the input unchanged', () {
    const md = '- [ ] a';
    expect(toggleTask(md, 1), md);
    expect(toggleTask(md, -1), md);
    expect(toggleTask('', 0), '');
  });
}
