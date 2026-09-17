def test_a8_deliberately_red():
    """A8 验证用：故意弄红，确认 backend pytest (full suite) 这道必需检查会拦住合并。

    看完就关掉那个 PR、删掉这个分支，**不要合**。
    """
    assert 1 == 2, "A8 故意弄红"
