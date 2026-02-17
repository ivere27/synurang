using System;

namespace Synurang;

public class PluginError : Exception
{
    public PluginError(string message) : base(message) { }
    public PluginError(string message, Exception inner) : base(message, inner) { }
}

public class PluginClosedError : PluginError
{
    public PluginClosedError() : base("plugin is closed") { }
}
