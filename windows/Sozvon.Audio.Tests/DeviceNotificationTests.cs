using System.Runtime.InteropServices;
using Sozvon.Audio.Capture;
using Xunit;

namespace Sozvon.Audio.Tests;

public class DeviceNotificationTests
{
    private const int OnDefaultDeviceChangedSlot = 6;

    [Theory]
    [InlineData((int)EDataFlow.Capture, (int)ERole.Console, 1)]
    [InlineData((int)EDataFlow.Render, (int)ERole.Console, 0)]
    [InlineData((int)EDataFlow.Capture, (int)ERole.Communications, 0)]
    public unsafe void WindowsCanCallTheClientThroughItsComInterface(int flow, int role, int expected)
    {
        int calls = 0;
        var client = new WasapiDevices.NotificationClient(EDataFlow.Capture, () => calls++);

        IntPtr pointer = Marshal.GetComInterfaceForObject<WasapiDevices.NotificationClient, IMMNotificationClient>(client);
        IntPtr id = Marshal.StringToCoTaskMemUni("{device}");
        try
        {
            var callback = (delegate* unmanaged[Stdcall]<IntPtr, int, int, IntPtr, int>)(*(IntPtr**)pointer)[OnDefaultDeviceChangedSlot];
            Assert.Equal(0, callback(pointer, flow, role, id));
        }
        finally
        {
            Marshal.FreeCoTaskMem(id);
            Marshal.Release(pointer);
        }

        Assert.Equal(expected, calls);
    }
}
