// Deliberately failing test for the step 2.6 notification test. Never merged: the pull request is closed.
describe('pipeline notification test', () => {
  it('fails on purpose, to see that the e-mail arrives', () => {
    expect(1).toBe(2);
  });
});
