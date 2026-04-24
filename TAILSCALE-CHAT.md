## Starter notes on tailscale workflow

Basically in the connect to server in settings on phone, the user should be provided an option to scan a QR code to connect instead of entering the details.

And on the computer where we have "Run this computer”, if the user must be shown a URL to signin into tailscale to approve the device, we provide a button to open the link in browser and also to copy the link.
And we keep running a spinner to check the user’s .

About the tailscale hostname for tsnet:
The hostname we will use for this service is derived from hostname of machine. “tincan-<machine-hostname>”. ofcourse the hostname has to be hyphenated to be part of FQDNS strings. so anything like “Akash’s MacBook air”, becomes “tincan-akashs-macbook-air”.

This doc has an example + notes about supporting 443 port - https://tailscale.com/docs/features/tsnet/how-to/create-basic-tsnet-app

I already setup a project in hello-tsnet subdir in our app.
Follow the docs here  - https://tailscale.com/docs/features/tsnet/how-to/create-basic-tsnet-app

When the sever started:

```
2026/04/24 13:08:39 tsnet running state path /Users/akash/Library/Application Support/tsnet-tshello/tailscaled.state
2026/04/24 13:08:39 tsnet starting with hostname "tshello", varRoot "/Users/akash/Library/Application Support/tsnet-tshello"
2026/04/24 13:08:39 LocalBackend state is NeedsLogin; running StartLoginInteractive...
2026/04/24 13:08:49 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:08:54 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:08:59 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:04 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:09 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:14 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:19 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:24 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:29 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:34 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:39 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:44 To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/1feec9e5016be6
2026/04/24 13:09:49 AuthLoop: state is Running; done
```

I got that url to use to provide permissions. That’s the URL we should parse and show in the UI.
If the node is alreayd permitted, we should see "AuthLoop: state is Running; done” without the like about handshake error + login url.

## Notes on server connection settings on mac

Looks like we need to introduce some option organization in settings, within the “Run on this computer” section, we should show another toggle for “Connect phone”. And now when the toggle is enabled, we will restart the tincan server with the tsnet wrapper. and then the same workflow I meantioned earlier when I shared  the tshello example.

we also need a way to fallback if tailscale is not enabled. so that we can inform the user on the same UI that tailscale needs to be installed and enabled. The only beahviour I know of is that if we dont have tailscale enabled, the tshello sample shuts down immediately. we should check if there is an error thrown that we can catch and inform on the stdout or stderr for the mac app to detect.

And similarly when tailscale is enabled and setup, then we can start tsnet wrapped server. but if that fails, we should restart the app without tailscale explicitly. like `--no-tailscale` (this is a switch we have to support in tincan-server.

## More notes on the connect workflow

For clarity. I think we can change the server that starts when “tincan-server” is run to “tincan-server run” first. Will be easier to organize.

so split into tincan-server/commands/run.go and tincan-server/commands/setup_tailscale.go?

Two things:
* I think it’s time to introduce cards in the Connect server screen on mac.
* Two cards. Run on this computer and Connect to server.
* Connect phone should be within the Run on this computer card.

When I enable connect phone switch I just see “Tailscale …. . . ..    disabled”
But this is when the "tincan-server setup-tailscale” command should be started and the mac app should monitor it for the command’s stdout and stderr messages. If it shows a login url we have to show it to the user with along with open link and copy buttons.

```
<spinner> Waiting for you to approve on Tailscale:
<login-link> <open link> <copy link>
```

When the user approves the log message changes to below:
```
2026/04/24 13:09:49 AuthLoop: state is Running; done
```

Then we
* Get the tailscale DNS name of the node we just started - 
```
domains := srv.CertDomains()
if len(domains) > 0 {
    // fmt.Printf("Node FQDN: %s\n", domains[0])
}
```
* pick the one with `.ts.net` (internet advice says thsi might come with a trailing dot so we have to strip that before using this fqdn.
* remove the login link and the waiting message. And instead show the QR code for the user to connect on phone to this server.
* Next to the QR code. Display the server details as as scheme+fqdn

If the device is already approved, you just get this message without the login link step. so you’ll know when to not show the login link.

If the user approves the link, the enable switch should be saved as “tailscale_enabled”: true in config.json along with “tailscale_node”:”<scheme>+<host>”.
And the tincan-server should be force-restarted by the mac app. Because it will then start with tailscale after it detects tailscale_enabled.

Next time the user visits this screen, the Connect to phone will be enabled because tailscale_enabled is true in config. And we will fetch the config to display the server url and the QR code to connect. I hope that when we start the "tincan-server run” process with tailscale when it is enabled, we have some kind of shared env somewhere to indicate that it is running with tailscale enabled mode. If tailscale fails to bind and we use —no-tailscale to start, then this indicator will help us know that tailscale is not being used despite being enabled. And on the settings screen in connect to phone, we can indicate that “Could not start with tailscale. Please ensure Tailscale is running".

And this “setup-tailscale” server process is a different server from what the main tincan-server the app starts.

Everytime we start the "tincan-server run” with tailscale enabled, fetch the ts.net domain of the node and ensure config.json has the same value. This helps.

## Things to watch out and do

* I think we should combine the scheme+host+port into one input box for the phone (and for "connect to server on" card in server settings on mac. This can be stored as "server_url" in the config.json. So the app (mac and ios both) can connect to this server on startup next time.

The `tincan-server setup-tailscale` command should start tailscale in port 80. For the "tincan-server run" command, tailscale should start on port 443. This means when the tincan-server is restarted (and if --no-tailscale is not passed), tailscale will use port 443.

When connecting on phone on the server settings screen on phone, the tailscale node might respond slower. 
When the user clicks on the Apply button, we should make a call to the health endpoint on the server to check. And we should retry every 5 seconds for upto 60 seconds. The apply button can be spinning at this time (and disabled). this is because the tailscale server might need some time to fetch it's ssl cert. Only after this we can save the server url in config.json as server_url: "<whatever>".

No legacy or fallback please to old config or implementations. This is exactly what we want.
