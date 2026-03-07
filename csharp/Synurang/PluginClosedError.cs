namespace Synurang;

public class PluginClosedError : FfiError
{
    public PluginClosedError() : base("plugin is closed") { }
}
