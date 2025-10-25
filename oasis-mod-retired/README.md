> [!IMPORTANT]
> This module contains deprecated features.  
> Therefore, its installation is not recommended.
>
> The following is a description of deprecated features.

## Ask OpenWrt Setting (Basic Usage)
Oasis is customizing the AI to specialize in OpenWrt. Therefore, it may prompt users to ask about OpenWrt. If a user requests configuration related to OpenWrt, the AI will suggest changes using UCI commands.  
<img width="946" height="443" alt="image" src="https://github.com/user-attachments/assets/bf4ad521-5b90-4a95-a847-a7d870413499" />
When a configuration change is suggested by the AI using UCI commands, the internal system of OpenWrt recognizes that a configuration change has been proposed by the AI. It then notifies the user via a popup to apply the configuration change to the current runtime. The user can accept the configuration change by pressing the Apply button.　　 
<img width="944" height="443" alt="image" src="https://github.com/user-attachments/assets/9a52798c-2887-41ec-b151-bed95f01d1c5" />
<img width="947" height="444" alt="image" src="https://github.com/user-attachments/assets/c9d2b1a7-d4d9-4471-b81b-80ef2c7e700e" /> 
After applying the settings, if the user can access the WebUI, they will be notified in the Oasis chat screen to finalize the configuration change suggested by the AI. The user can press the Finalize button to approve the configuration change, or press the Rollback button to reject it.　　
<img width="946" height="442" alt="image" src="https://github.com/user-attachments/assets/b69221e9-856d-47f8-ad1e-af879ae558e0" />
 
> [!IMPORTANT]
> After a configuration change, if the user does not press the Finalize or Rollback button within 5 minutes (default), the configuration will automatically rollback (Rollback monitoring). This ensures that even if there was a configuration error that caused a brick, the system will return to the original, normal settings. Note: If the OpenWrt device is powered off during the rollback monitoring period, the rollback monitoring will resume upon restart.

## Ask OpenWrt Setting (Advanced Usage)
> [!NOTE]
> The following is an effective usage method when using high-performance LLMs such as OpenAI.

If you are willing to provide your current settings to the AI, you can select UCI Config from the dropdown menu below the message box. When you provide this as supplementary information when making a request to the AI, the accuracy of its suggestions will improve significantly. For example, as shown in the following case.

In the following example, Wi-Fi is enabled, and when requesting some configuration changes, the current wireless settings are provided to the AI as reference information.
<img width="1887" height="881" alt="image" src="https://github.com/user-attachments/assets/167c2691-c5d6-4b4c-88a1-3a82a96bb6ca" />  
When you send a message to the AI, the selected configuration information (e.g., wireless settings) will be added at the bottom.  
> [!IMPORTANT]
> After pressing the Send button, select ```OpenWrt Teacher (for High-Performance LLM)``` from the list of system messages displayed.
<img width="946" height="443" alt="image" src="https://github.com/user-attachments/assets/c8ea11d1-e6fa-4c9b-9982-b1dbfdc7bfcd" />  

By providing the current configuration information, the accuracy of the AI's suggestions improves.  
<img width="946" height="445" alt="image" src="https://github.com/user-attachments/assets/baa28d6d-2c5b-4082-a780-dcf4e80c120e" />  
<img width="944" height="449" alt="image" src="https://github.com/user-attachments/assets/7dae99a1-8fad-4b6a-a55e-efc3f719ef2d" />  
<img width="947" height="443" alt="image" src="https://github.com/user-attachments/assets/8fd37066-4ab3-4534-ae42-18ec6540f94e" /> 

## Rollback Data List
AI-driven configuration changes are saved as rollback data, allowing users to revert settings to any desired point.
<img width="944" height="444" alt="image" src="https://github.com/user-attachments/assets/7f65108a-674e-435b-824d-69933e70d80e" />　　  
