
namespace Station.Simulation
{
    using Opc.Ua;
    using Opc.Ua.Server;
    using System;
    using System.Collections.Generic;

    public partial class FactoryStationServer : StandardServer
    {
        private bool _isStation = false;

        public FactoryStationServer(bool isStation)
        {
            _isStation = isStation;
        }

        protected override MasterNodeManager CreateMasterNodeManager(IServerInternal server, ApplicationConfiguration configuration)
        {
            List<INodeManager> nodeManagers = new List<INodeManager>();

            if (_isStation)
            {
                nodeManagers.Add(new StationNodeManager(server, configuration));
            }
            else
            {
                nodeManagers.Add(new MESNodeManager(server, configuration));
            }

            return new MasterNodeManager(server, configuration, null, nodeManagers.ToArray());
        }

        protected override ServerProperties LoadServerProperties()
        {
            ServerProperties properties = new ServerProperties
            {
                ManufacturerName = "DTC",
                ProductName = "Factory Station Simulation",
                ProductUri = "",
                SoftwareVersion = Utils.GetAssemblySoftwareVersion(),
                BuildNumber = Utils.GetAssemblyBuildNumber(),
                BuildDate = Utils.GetAssemblyTimestamp()
            };

            return properties;
        }

        protected override void OnServerStarted(IServerInternal server)
        {
            base.OnServerStarted(server);

            server.SessionManager.ImpersonateUser += new ImpersonateEventHandler(SessionManager_ImpersonateUser);
        }

        private void SessionManager_ImpersonateUser(ISession session, ImpersonateEventArgs args)
        {
            UserNameIdentityToken userNameToken = args.NewIdentity as UserNameIdentityToken;
            if (userNameToken != null)
            {
                args.Identity = VerifyPassword(userNameToken);

                Utils.LogInfo(Utils.TraceMasks.Security, "Username token accepted: {0}", args.Identity?.DisplayName);
                return;
            }

            AnonymousIdentityToken anonymousToken = args.NewIdentity as AnonymousIdentityToken;
            if (anonymousToken != null)
            {
                Utils.LogInfo(Utils.TraceMasks.Security, "Anonymous token accepted: {0}", args.Identity?.DisplayName);
                return;
            }

            throw ServiceResultException.Create(StatusCodes.BadIdentityTokenInvalid, "Not supported user token type: {0}.", args.NewIdentity);
        }

        private IUserIdentity VerifyPassword(UserNameIdentityToken userNameToken)
        {
            var userName = userNameToken.UserName;
            var password = userNameToken.DecryptedPassword;

            if (string.IsNullOrEmpty(userName))
            {
                throw ServiceResultException.Create(StatusCodes.BadIdentityTokenInvalid,
                    "Security token is not a valid username token. An empty username is not accepted.");
            }

            if (string.IsNullOrEmpty(password))
            {
                throw ServiceResultException.Create(StatusCodes.BadIdentityTokenRejected,
                    "Security token is not a valid username token. An empty password is not accepted.");
            }

            string configuredUsername = Environment.GetEnvironmentVariable("OPCUA_USERNAME");
            string configuredPassword = Environment.GetEnvironmentVariable("OPCUA_PASSWORD");

            if (!string.IsNullOrEmpty(configuredUsername)
             && !string.IsNullOrEmpty(configuredPassword)
             && (userName == configuredUsername)
             && (password == configuredPassword))
            {
                return new SystemConfigurationIdentity(new UserIdentity(userNameToken));
            }

            // construct translation object with default text.
            TranslationInfo info = new TranslationInfo(
                "InvalidPassword",
                "en-US",
                "Invalid username or password.",
                userName);

            // create an exception with a vendor defined sub-code.
            throw new ServiceResultException(new ServiceResult(
                StatusCodes.BadUserAccessDenied,
                "InvalidPassword",
                LoadServerProperties().ProductUri,
                new LocalizedText(info)));
        }
    }
}
