package org.jmx4perl;

import org.jmx4perl.handler.RequestHandler;

import javax.management.*;
import javax.naming.InitialContext;
import javax.naming.NamingException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.*;

/*
 * jmx4perl - WAR Agent for exporting JMX via JSON
 *
 * Copyright (C) 2009 Roland Huß, roland@cpan.org
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 *
 * A commercial license is available as well. Please contact roland@cpan.org for
 * further details.
 */

/**
 * Handler for finding and merging various MBeanServers.
 *
 * @author roland
 * @since Jun 15, 2009
 */
public class MBeanServerHandler {

    // The MBeanServers to use
    private Set mBeanServers;

    // Whether we are running under JBoss
    boolean isJBoss = checkForClass("org.jboss.mx.util.MBeanServerLocator");
    boolean isWebsphere = checkForClass("com.ibm.websphere.management.AdminServiceFactory");

    public MBeanServerHandler() {
        mBeanServers = findMBeanServers();
        for (Iterator it = mBeanServers.iterator(); it.hasNext(); ) {
            System.out.println(">>>>> " + it.next());
        }
    }

    /**
     * Dispatch a request to the MBeanServer which can handle it
     *
     * @param pRequestHandler request handler to be called with an MBeanServer
     * @param pJmxReq the request to dispatch
     * @return the result of the request
     */
    public Object dispatchRequest(RequestHandler pRequestHandler, JmxRequest pJmxReq)
            throws InstanceNotFoundException, AttributeNotFoundException, ReflectionException, MBeanException {
        if (pRequestHandler.handleAllServersAtOnce()) {
            return pRequestHandler.handleRequest(mBeanServers,pJmxReq);
        } else {
            try {
                wokaroundJBossBug(pJmxReq);
                AttributeNotFoundException attrException = null;
                InstanceNotFoundException objNotFoundException = null;
                for (Iterator it = mBeanServers.iterator();it.hasNext();) {
                    MBeanServer s = (MBeanServer) it.next();
                    try {
                        return pRequestHandler.handleRequest(s, pJmxReq);
                    } catch (InstanceNotFoundException exp) {
                        // Remember exceptions for later use
                        objNotFoundException = exp;
                    } catch (AttributeNotFoundException exp) {
                        attrException = exp;
                    }
                }
                if (attrException != null) {
                    throw attrException;
                }
                // Must be there, otherwise we would nave have left the loop
                throw objNotFoundException;
            } catch (ReflectionException e) {
                throw new RuntimeException("Internal error for '" + pJmxReq.getAttributeName() +
                        "' on object " + pJmxReq.getObjectName() + ": " + e,e);
            } catch (MBeanException e) {
                throw new RuntimeException("Exception while fetching the attribute '" + pJmxReq.getAttributeName() +
                        "' on object " + pJmxReq.getObjectName() + ": " + e,e);
            }
        }
    }

    /**
     * Register a MBean under a certain name to the first availabel MBeans server
     *
     * @param pMBean MBean to register
     * @param pName optional name under which the bean should be registered. If not provided,
     * it depends on whether the MBean to register implements {@link javax.management.MBeanRegistration} or
     * not.
     *
     * @return the name under which the MBean is registered.
     */
    public ObjectName registerMBean(Object pMBean,String pName)
            throws MalformedObjectNameException, NotCompliantMBeanException, MBeanRegistrationException, InstanceAlreadyExistsException {
        if (mBeanServers.size() > 0) {
            Exception lastExp = null;
            for (Iterator it = mBeanServers.iterator();it.hasNext();) {
                    MBeanServer server = (MBeanServer) it.next();
                    try {
                    if (pName != null) {
                        ObjectName oName = new ObjectName(pName);
                        return server.registerMBean(pMBean,oName).getObjectName();
                    } else {
                        // Needs to implement MBeanRegistration interface
                        return server.registerMBean(pMBean,null).getObjectName();
                    }
                } catch (Exception exp) {
                    lastExp = exp;
                }
            }
            if (lastExp != null) {
                throw new IllegalStateException("Could not register " + pMBean + ": " + lastExp);
            }
            //ManagementFactory.getPlatformMBeanServer().registerMBean(configMBean,name);
        }
        throw new IllegalStateException("No MBeanServer initialized yet");
    }

    /**
     * Unregisters a MBean under a certain name to the first availabel MBeans server
     *
     * @param pMBeanName object name to unregister
     */
    public void unregisterMBean(ObjectName pMBeanName)
            throws MBeanRegistrationException, InstanceNotFoundException, MalformedObjectNameException {
        if (mBeanServers.size() > 0) {
            ((MBeanServer) mBeanServers.iterator().next()).unregisterMBean(pMBeanName);
        } else {
            throw new IllegalStateException("No MBeanServer initialized yet");
        }
    }

    /**
     * Get the set of MBeanServers found
     *
     * @return set of mbean servers
     */
    public Set getMBeanServers() {
        return Collections.unmodifiableSet(mBeanServers);
    }

    // =================================================================================

    /**
     * Use various ways for getting to the MBeanServer which should be exposed via this
     * servlet.
     *
     * <ul>
     *   <li>If running in JBoss, use <code>org.jboss.mx.util.MBeanServerLocator</code>
     *   <li>Use {@link javax.management.MBeanServerFactory#findMBeanServer(String)} for
     *       registered MBeanServer and take the <b>first</b> one in the returned list
     * </ul>
     *
     * @return the MBeanServer found
     * @throws IllegalStateException if no MBeanServer could be found.
     */
    private Set findMBeanServers() {

        // Check for JBoss MBeanServer via its utility class
        Set servers = new LinkedHashSet();

        addJBossMBeanServer(servers);
        addWebsphereMBeanServer(servers);
        addFromMBeanServerFactory(servers);
        addFromJndiContext(servers);
        addFromWeblogicJndi(servers);
        addPlatformMBeanServer(servers);

        if (servers.size() == 0) {
			throw new IllegalStateException("Unable to locate any MBeanServer instance");
		}

		return servers;
	}

    private void addPlatformMBeanServer(Set pServers) {
        // Do it by reflection
        try {
            Class managementFactory = Class.forName("java.lang.management.ManagementFactory");
            Method method = managementFactory.getMethod("getPlatformMBeanServer",null);
            MBeanServer server = (MBeanServer) method.invoke(null,null);
            if (server != null) {
                pServers.add(server);
            }

        } catch (ClassNotFoundException exp) {

        } catch (NoSuchMethodException e) {
            throw new IllegalStateException("No method getPlatformMBeanServer found: " + e);
        } catch (IllegalAccessException e) {
            throw new IllegalStateException("Error while invoking getPlatformMBeanServer: " + e);
        } catch (InvocationTargetException e) {
            throw new IllegalStateException("Error while invoking getPlatformMBeanServer: " + e);
        }
    }

    private void addFromWeblogicJndi(Set pServers) {
        try {
            Class mbeanHomeClass = Class.forName("weblogic.management.MBeanHome");
            String jndiName = (String) mbeanHomeClass.getField("LOCAL_JNDI_NAME").get(null);
            InitialContext ctx = new InitialContext();

            Object mbeanHome = ctx.lookup(jndiName);
            if (mbeanHome != null) {
                MBeanServer mbeanServer =
                        (MBeanServer)
                                mbeanHome.getClass().getMethod("getMBeanServer", null).invoke(mbeanHome, null);
                if (mbeanServer != null) {
                    pServers.add(mbeanServer);
                } else {
                    throw new IllegalStateException("No MBeanServer found on Weblogics MBeanHome");
                }
            } else {
                throw new IllegalStateException("No MBeanHome found");
            }
        }  catch (NamingException e) {
            throw new IllegalStateException("No Weblogic MBeanHome found: " + e);
        } catch (ClassNotFoundException e) {
            System.err.println("No Weblogic MBeanHome class found. Ignoring ...");
        } catch (NoSuchMethodException e) {
            throw new IllegalStateException("No method getMBeanServer found on class weblogic.management.MBeanHome");
        } catch (IllegalAccessException e) {
            throw new IllegalStateException("Error while calling weblogic.management.MBeanHome.getMBeanServer()");
        } catch (InvocationTargetException e) {
            throw new IllegalStateException("Error while calling weblogic.management.MBeanHome.getMBeanServer()");
        } catch (NoSuchFieldException e) {
            throw new IllegalStateException("No method getMBeanServer found on class weblogic.management.MBeanHome");
        }
    }

    private void addFromJndiContext(Set servers) {
        // Weblogic stores the MBeanServer in a JNDI context
        InitialContext ctx;
        try {
            ctx = new InitialContext();
            MBeanServer server = (MBeanServer) ctx.lookup("java:comp/env/jmx/runtime");
            if (server != null) {
                servers.add(server);
            }
        } catch (NamingException e) { /* can happen on non-Weblogic platforms */ }
    }

    private void addWebsphereMBeanServer(Set servers) {
        try {
			/*
			 * this.mbeanServer = AdminServiceFactory.getMBeanFactory().getMBeanServer();
			 */
			Class adminServiceClass = getClass().getClassLoader().loadClass("com.ibm.websphere.management.AdminServiceFactory");
			Method getMBeanFactoryMethod = adminServiceClass.getMethod("getMBeanFactory", new Class[0]);
			Object mbeanFactory = getMBeanFactoryMethod.invoke(null, new Object[0]);
			Method getMBeanServerMethod = mbeanFactory.getClass().getMethod("getMBeanServer", new Class[0]);
			servers.add((MBeanServer) getMBeanServerMethod.invoke(mbeanFactory, new Object[0]));
		}
		catch (ClassNotFoundException ex) {
            // Expected if not running under WAS
		}
		catch (InvocationTargetException ex) {
            // CNFE should be earluer
            throw new IllegalArgumentException("Internal: Found AdminServiceFactory but can not call methods on it (wrong WAS version ?)");
		} catch (IllegalAccessException e) {
            throw new IllegalArgumentException("Internal: Found AdminServiceFactory but can not call methods on it (wrong WAS version ?)");
        } catch (NoSuchMethodException e) {
            throw new IllegalArgumentException("Internal: Found AdminServiceFactory but can not call methods on it (wrong WAS version ?)");
        }
    }

    // Special handling for JBoss
    private void addJBossMBeanServer(Set servers) {
        try {
            Class locatorClass = Class.forName("org.jboss.mx.util.MBeanServerLocator");
            Method method = locatorClass.getMethod("locateJBoss",null);
            servers.add((MBeanServer) method.invoke(null,null));
        }
        catch (ClassNotFoundException e) { /* Ok, its *not* JBoss, continue with search ... */ }
        catch (NoSuchMethodException e) { }
        catch (IllegalAccessException e) { }
        catch (InvocationTargetException e) { }
    }

    // Lookup from MBeanServerFactory
    private void addFromMBeanServerFactory(Set servers) {
        List beanServers = MBeanServerFactory.findMBeanServer(null);
        if (beanServers != null) {
            servers.addAll(beanServers);
        }
    }

    // =====================================================================================

    private void wokaroundJBossBug(JmxRequest pJmxReq) throws ReflectionException, InstanceNotFoundException {
        // if ((isJBoss || isWebsphere)
        // The workaround was enabled for websphere as well, but it seems
        // to work without it for WAS 7.0
        if (isJBoss && "java.lang".equals(pJmxReq.getObjectName().getDomain())) {
            try {
                // invoking getMBeanInfo() works around a bug in getAttribute() that fails to
                // refetch the domains from the platform (JDK) bean server (e.g. for MXMBeans)
                for (Iterator it = mBeanServers.iterator();it.hasNext();) {
                    MBeanServer s = (MBeanServer) it.next();
                    try {
                        s.getMBeanInfo(pJmxReq.getObjectName());
                        return;
                    } catch (InstanceNotFoundException exp) {
                        // Only one server can have the name. So, this exception
                        // is being expected to happen
                    }
                }
            } catch (IntrospectionException e) {
                throw new RuntimeException("Workaround for JBoss failed for object " + pJmxReq.getObjectName() + ": " + e);
            }
        }
    }

    private boolean checkForClass(String pClassName) {
        try {
            Class.forName(pClassName);
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }


}