This application is currently under development.
Therefore, some commands may not be available.

```
root@OpenWrt:~# aihelper
Usage: aihelper <command> [[<options>] arguments]...

Options:
 -n <service>           Set the service name
 -u <url>               Set the url or ipaddr for ai service
 -k <api-key>           Set the api-key for ai service
 -m <model>             Set the llm model for ai service
 -s enable or disable   Set the storage enable/disable

Commands:
 - storage <path> [<chat-max>] (default: chat-max = 30)
 - add [<service> [<url> [<api-key> [<model> [<storage>]]]]]
 - change <service> [<options> <argument>]...
 - select [<service>]
 - delete <service>
 - chat [id=<chat-id>]
 - prompt
 - delchat <id>
 - rename <id> <title>
 - list [[chat] [knowledge]]
 - test <service>
 - call <script> <messsage>

Docs
        https://utakamo.com
```
Example of setting up an AI server (Ollama) 
> [!NOTE]
> Due to ongoing development, cloud-based AI services such as ChatGPT are not available.
```
root@OpenWrt:~# aihelper add
Please enter any service name  :ollama
URL                            :http://192.168.3.12:11434/api/chat 
API KEY (leave blank if none)  :
LLM MODEL                      :gemma2:2b
USE INTERNAL STORAGE? (ON/OFF) :ON
```
Example of chat with ai
```
root@OpenWrt:~# aihelper chat
You :Hello!
gemma2:2b
Hello! 👋  

How can I help you today? 😄
```
